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
	--cmd-string 'wget -U "$(USER_AGENT)" {base_url}{srcfile} -O temp_data/{local_file}; pause 1' \
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
	#____________________________________________________________________
	#

	cat temp_data/file_ingest_manifest.json | ngst --config config/ingest_file_assets.yaml --target s3
	cat temp_data/file_ingest_manifest.json | ngst --config config/ingest_file_assets.yaml --target db



pipeline-filedata-refresh: dl-manifest get-headers gen-metahashes
	$(eval USER_AGENT=Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0)

	#____________________________________________________________________
	#
	# After we get the HTTP file headers (but before we download data),
	# we will filter the ingestion manifest, rejecting all the records corresponding to
	# files we've stored in the database.
	#  
	# (We run jfiltr in "reject" mode, which will write rejected records to a designated file
	# -- in this case, /dev/null -- and emit the records we want to stdout)
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
	--cmd-string 'wget -U "$(USER_AGENT)" {base_url}{srcfile} -O temp_data/{local_file}; pause 1' \
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



get-apidata-single:
	beekeeper --config config/bkpr_datausa.yaml --target state | jq -r .data \
	> temp_data/pop_data_state.json

	beekeeper --config config/bkpr_datausa.yaml --target nation | jq -r .data \
	> temp_data/pop_data_nation.json



