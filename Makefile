##
## Makefile for Rearc pipelines
##


	#____________________________________________________________________
	#
	# 
	#
	#____________________________________________________________________
	#

required-dirs:
	cat required_dirs.txt | xargs mkdir -p


clean:
	rm -f temp_data/*
	rm -f temp_scripts/*
	rm -f temp_sql/*


infra-setup:
	./setup_infra.sh


db-up:
	docker compose up -d


db-down:
	docker compose down


dblogin:
	psql -U user --port=15433 --host=localhost -W

dbalogin:
	psql -U reqdba --port=15433 --host=localhost -d reqdb
 

gen-dba-script:
	warp --py --template-file=template_files/mkdbauser.sql.tpl \
	--params=role:reqdba,description:Administrator,pw:$$REQ_DBA_PASSWORD,db_name:reqdb \
	> temp_sql/create_dba_role.sql


gen-db-script: 
	warp --py --template-file=template_files/mkdb.sql.tpl --params=db_name:reqdb \
	> temp_sql/create_db.sql


gen-perm-script:
	warp --py --template-file=template_files/perms.sql.tpl --params=db_name:reqdb,role:reqdba \
	> temp_sql/set_perms.sql


db-create-database:
	psql -U user --port=15433 --host=localhost -W -f temp_sql/create_db.sql


db-create-dbauser:
	psql -U user --port=15433 --host=localhost  -W -f temp_sql/create_dba_role.sql


db-set-perms:
	psql -U user --port=15433 --host=localhost  -W -f temp_sql/set_perms.sql



db-purge:
	psql -U user --port=15433 --host=localhost  -W -f sql/purge.sql


db-create-tables:	

	export PGPASSWORD=$$REQ_DBA_PASSWORD && psql -U reqdba --port=15433 --host=localhost -d reqdb -w -f sql/req_db_extensions.sql
	export PGPASSWORD=$$REQ_DBA_PASSWORD && psql -U reqdba --port=15433 --host=localhost -d reqdb -w -f sql/req_ddl.sql


db-init: gen-db-script gen-dba-script gen-perm-script db-create-database db-create-dbauser db-set-perms db-create-tables



dl-manifest:
	$(eval BASE_URL=https://download.bls.gov)

	#____________________________________________________________________
	#
	# Generate a structured-data manifest to drive our download operations
	#
	#____________________________________________________________________
	#

	lftp -c du -a $(BASE_URL)/pub/time.series/pr/ \
	| awk '{ print $$2 }' | scripts/filter_path_list.py > temp_data/src_datafiles.txt

	repeat --linecount temp_data/src_datafiles.txt --str $(BASE_URL) > temp_data/base_urls.txt

	cat temp_data/src_datafiles.txt | awk -F/ '{print $$NF}' > temp_data/local_filenames.txt

	loopr -p -t --listfile temp_data/local_filenames.txt --vartoken % \
	--cmd-string '%.hdr' > temp_data/header_filenames.txt

	tuplegen --delimiter '|' \
	--listfiles=temp_data/base_urls.txt,temp_data/src_datafiles.txt,temp_data/local_filenames.txt,temp_data/header_filenames.txt \
	| tuple2json --delimiter '|' --keys=base_url,srcfile,local_file,header_file > temp_data/file_download_manifest.json


get-headers:
	$(eval USER_AGENT=Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0)

	#____________________________________________________________________
	#
	# here we pull the HTTP headers for each file in the target location 
	#
	#____________________________________________________________________
	#

	cp template_files/shell_script_core.sh.tpl temp_scripts/download_headers.sh

	loopr -p -j --listfile temp_data/file_download_manifest.json \
	--cmd-string 'curl -A "$(USER_AGENT)" -I {base_url}{srcfile} > temp_data/{header_file}' \
	>> temp_scripts/download_headers.sh

	chmod u+x temp_scripts/download_headers.sh
	temp_scripts/download_headers.sh


get-filedata:
	$(eval USER_AGENT=Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0)

	#____________________________________________________________________
	#
	# download the actual datafiles, using our generated manifest as a guide
	#
	#____________________________________________________________________
	#

	cp template_files/shell_script_core.sh.tpl temp_scripts/download_files.sh

	loopr -p -j --listfile temp_data/file_download_manifest.json \
	--cmd-string 'wget -U "$(USER_AGENT)" {base_url}{srcfile} -O temp_data/{local_file}' \
	>> temp_scripts/download_files.sh

	chmod u+x temp_scripts/download_files.sh
	temp_scripts/download_files.sh


gen-metahashes:

	#____________________________________________________________________
	#
	# A "metahash" is a hash of specific fields from the HTTP header for each
	# file in the target list. In this case, we want length-of-file and the date
	# the file was last modified. 
	#
	# We will use this data to update our persistent datastore, so that we can 
	# compare future downloads with what we've already done. If a file is modified
	# on the server, its metahash will not match the existing, and we'll know
	# we need to re-download.
	#
	#____________________________________________________________________
	#

	loopr -j --listfile temp_data/file_download_manifest.json \
	--cmd-string 'scripts/parse_header.py --file temp_data/{header_file} --fields=content-length,last-modified' \
	> temp_data/header_fields.jsonl

	cp template_files/shell_script_core.sh.tpl temp_scripts/generate_metahashes.sh

	loopr -p -t --listfile temp_data/header_fields.jsonl --vartoken % \
	--cmd-string "md5sum <<< '%'" >> temp_scripts/generate_metahashes.sh

	chmod u+x temp_scripts/generate_metahashes.sh
	temp_scripts/generate_metahashes.sh > temp_data/metahashes.txt

	#____________________________________________________________________
	#
	# Here, we update the download-manifest to include the metahash for each file.
	# When we feed the manifest to our ingest routine, those values will be included.
	#
	#____________________________________________________________________
	#

	mergein2j --from-list temp_data/metahashes.txt --key metahash --into temp_data/file_download_manifest.json \
	> temp_data/file_ingest_manifest.json


pipeline-filedata-init-upload: dl-manifest get-headers get-filedata gen-metahashes

	#____________________________________________________________________
	#
	# ngst is a general-purpose ingestion utility; the actual ingestion logic lives 
	# in the Datasource designated in the initfile. Therefore we can use the same utility
	# and the same command structure to upload to S3 and to ingest to our PostgreSQL instance.
	#
	# And yes, we could technically collapse this target and its "refresh" sibling into one, but having
	# them separate makes testing easier. DOTS ;-)
	#
	#____________________________________________________________________
	#

	cat temp_data/file_ingest_manifest.json | ngst --config config/ingest_file_assets.yaml --target s3
	cat temp_data/file_ingest_manifest.json | ngst --config config/ingest_file_assets.yaml --target db


pipeline-filedata-refresh: dl-manifest get-headers gen-metahashes
	$(eval USER_AGENT=Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0)

	#____________________________________________________________________
	#
	# After we get the HTTP file headers (but before we download data),
	# we will 
	#
	# (a) detect any deletions, and 
	# (b) filter the ingestion manifest
	#____________________________________________________________________
	#

	#____________________________________________________________________
	#
	# Query the database, then run a custom script comparing the file assets in our DB
	# to our latest download records
	#____________________________________________________________________
	#

	export PGPASSWORD=$$REQ_DBA_PASSWORD && psql -U reqdba --port=15433 --host=localhost -d reqdb -w -f sql/all_assets.sql \
	| tail -n +2 > temp_data/all_db_assets.jsonl

	cat temp_data/all_db_assets.jsonl | jq .[] | jq -r .filename > temp_data/db_asset_filenames.txt

	scripts/detect_deletions.py --manifest temp_data/file_ingest_manifest.json --dbassets temp_data/db_asset_filenames.txt \
	> temp_data/deleted_files.txt

	#____________________________________________________________________
	#
	# Now that we have a list of deleted files (assets which are logged in the database, but do not appear
	# in the latest download manifest), we apply those to the database and to S3.
	#
	# Here we can use ngst for the DB step, specifying the "deletion" record type.
	#____________________________________________________________________
	#
	
	cat temp_data/deleted_files.txt | tuple2json --delimiter ',' --keys=deleted_filename \
	> temp_data/deleted_files.jsonl

	cat temp_data/deleted_files.jsonl | ngst --config config/ingest_file_assets.yaml --target db --params=record_type:deletion \
	> temp_data/s3_deletion_targets.jsonl

	#____________________________________________________________________
	#
	# We set the database operation to emit the deletion records, so that a failed
	# DB op will not result in an S3 deletion. Now we use that output to generate
	# the proper S3 commands.
	#____________________________________________________________________
	#

	repeat --linecount temp_data/s3_deletion_targets.jsonl --str `cat data/infra_setup.json | jq .s3_bucket_id.value -r` \
	> temp_data/s3_bucket_ids.txt

	loopr -p -j --listfile temp_data/s3_deletion_targets.jsonl \
	--cmd-string '{deleted_filename}' > temp_data/s3_delete_files.txt

	tuplegen --delimiter ',' --listfiles=temp_data/s3_bucket_ids.txt,temp_data/s3_delete_files.txt \
	| tuple2json --delimiter ',' --keys=bucket,file > temp_data/s3_deletion_manifest.jsonl
	
	#____________________________________________________________________
	#
	# Running loopr in normal mode (without the -p flag, which is for "preview") causes it
	# to execute the command string, rather than simply emitting it to stdout
	#
	#____________________________________________________________________ 

	loopr -j --listfile temp_data/s3_deletion_manifest.jsonl \
	--cmd-string 'aws s3 rm s3://{bucket}/{file}'

	#____________________________________________________________________
	#
	# Now we run jfiltr against our manifest in "reject" mode, which will write rejected records to a 
	# designated file -- in this case, /dev/null -- and emit the records we want to stdout.
	#
	# A record is rejected if its "metahash" field has no match in the database BUT the filename exists,
	# which means that a file has changed on the server
	#____________________________________________________________________
	#

	rm -f temp_data/filtered_file_ingest_manifest.jsonl

	jfiltr --config config/filter_dl_manifest.yaml --setup test \
	--source temp_data/file_ingest_manifest.json > temp_data/filtered_file_ingest_manifest.jsonl

	#____________________________________________________________________
	#
	# Download only the changed datafiles, using our filtered manifest as a guide
	#
	#____________________________________________________________________
	#

	cp template_files/shell_script_core.sh.tpl temp_scripts/download_updated_files.sh

	loopr -p -j --listfile temp_data/filtered_file_ingest_manifest.jsonl \
	--cmd-string 'wget -U "$(USER_AGENT)" {base_url}{srcfile} -O temp_data/{local_file}' \
	>> temp_scripts/download_updated_files.sh

	chmod u+x temp_scripts/download_updated_files.sh
	temp_scripts/download_updated_files.sh

	#____________________________________________________________________
	#
	# Use the filtered manifest to upload and then ingest ONLY the updated files
	#
	#____________________________________________________________________
	#

	cat temp_data/filtered_file_ingest_manifest.jsonl | ngst --config config/ingest_file_assets.yaml --target s3
	cat temp_data/filtered_file_ingest_manifest.jsonl | ngst --config config/ingest_file_assets.yaml --target db


pipeline-get-apidata:

	beekeeper --config config/bkpr_datausa.yaml --target nation | jq -r .data | jq .data \
	> data/pop_data_nation.json

	aws s3 cp data/pop_data_nation.json s3://`cat data/infra_setup.json | jq .s3_bucket_id.value -r`


pipeline-api-stats: pipeline-get-apidata

	scripts/dfscan.py data/pop_data_nation.json --stats=Population:std,Population:mean

	
pipeline-frame-readout: # test target

	scripts/wscollapse.py --listfile temp_data/pr.data.0.Current --delimiter ',' \
	| tail -n +2 | tuple2json --delimiter ',' --keys=series_id,year,period,value \
	> data/bls_dataset.jsonl

	scripts/dfscan.py --listfile data/bls_dataset.jsonl


