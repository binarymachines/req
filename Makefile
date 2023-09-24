

required-dirs:
	cat required_dirs.txt | xargs mkdir -p


dl-manifest:
	$(eval BASE_URL=https://download.bls.gov)

	#lftp -c du -a https://download.bls.gov/pub/time.series/pr/ \
	#| awk '{ print $$2 }' | scripts/filter_path_list.py > temp_data/src_datafiles.txt

	repeat --linecount temp_data/src_datafiles.txt --str $(BASE_URL) > temp_data/base_urls.txt

	cat temp_data/src_datafiles.txt | awk -F/ '{print $$NF}' > temp_data/local_filenames.txt

	loopr -p -t --listfile temp_data/local_filenames.txt --vartoken % \
	--cmd-string '%.hdr' > temp_data/header_filenames.txt

	tuplegen --delimiter '|' \
	--listfiles=temp_data/base_urls.txt,temp_data/src_datafiles.txt,temp_data/local_filenames.txt,temp_data/header_filenames.txt \
	| tuple2json --delimiter '|' --keys=base_url,srcfile,local_file,header_file > temp_data/file_download_manifest.json


get-headers:
	$(eval USER_AGENT=Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0)

	cp template_files/shell_script_core.sh.tpl temp_scripts/download_headers.sh

	loopr -p -j --listfile temp_data/file_download_manifest.json \
	--cmd-string 'curl -A "$(USER_AGENT)" -I {base_url}{srcfile} > temp_data/{header_file}' \
	>> temp_scripts/download_headers.sh

	chmod u+x temp_scripts/download_headers.sh
	temp_scripts/download_headers.sh


get-filedata:
	$(eval USER_AGENT=Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0)

	cp template_files/shell_script_core.sh.tpl temp_scripts/download_files.sh

	loopr -p -j --listfile temp_data/file_download_manifest.json \
	--cmd-string 'wget -U "$(USER_AGENT)" {base_url}{srcfile} -O temp_data/{local_file}; pause 1' \
	>> temp_scripts/download_files.sh

	chmod u+x temp_scripts/download_files.sh
	temp_scripts/download_files.sh


gen-metahashes:
	loopr -j --listfile temp_data/file_download_manifest.json \
	--cmd-string 'scripts/parse_header.py --file temp_data/{header_file} --fields=content-length,last-modified' \
	> temp_data/header_fields.jsonl

	cp template_files/shell_script_core.sh.tpl temp_scripts/generate_metahashes.sh

	loopr -p -t --listfile temp_data/header_fields.jsonl --vartoken % \
	--cmd-string "md5sum <<< '%'" >> temp_scripts/generate_metahashes.sh

	chmod u+x temp_scripts/generate_metahashes.sh
	temp_scripts/generate_metahashes.sh > temp_data/metahashes.txt

	mergein2j --from-list temp_data/metahashes.txt --key metahash --into temp_data/file_download_manifest.json \
	> temp_data/file_ingest_manifest.json


get-apidata:
	beekeeper --config config/bkpr_datausa.yaml --target state | jq -r .data \
	> temp_data/pop_data_state.json

	beekeeper --config config/bkpr_datausa.yaml --target nation | jq -r .data \
	> temp_data/pop_data_nation.json


scratch:
	cp template_files/shell_script_core.sh.tpl temp_scripts/read_headers.sh

	loopr -p -t --listfile temp_data/src_datafiles.txt --vartoken % \
	--cmd-string 'curl -I https://download.bls.gov% | scripts/parse_header.py' \
	>> temp_scripts/read_headers.sh

	chmod u+x temp_scripts/read_headers.sh
	
	#countup --from 1 --to `wc -l temp_data/local_filenames.txt` > temp_data/file_indices.txt

	#loopr -p -t --listfile temp_data/local_filenames.txt --vartoken % \
	#--cmd-string ''


