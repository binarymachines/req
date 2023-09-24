

required-dirs:
	cat required_dirs.txt | xargs mkdir -p


list-datafiles:
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


scratch:
	cp template_files/shell_script_core.sh.tpl temp_scripts/read_headers.sh

	loopr -p -t --listfile temp_data/src_datafiles.txt --vartoken % \
	--cmd-string 'curl -I https://download.bls.gov% | scripts/parse_header.py' \
	>> temp_scripts/read_headers.sh

	chmod u+x temp_scripts/read_headers.sh
	
	#countup --from 1 --to `wc -l temp_data/local_filenames.txt` > temp_data/file_indices.txt

	#loopr -p -t --listfile temp_data/local_filenames.txt --vartoken % \
	#--cmd-string ''



download-files:
	echo 'placeholder'
	
