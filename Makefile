

required-dirs:
	cat required_dirs.txt | xargs mkdir -p


list-datafiles:
	$(eval BASE_URL=https://download.bls.gov)

	lftp -c du -a https://download.bls.gov/pub/time.series/pr/ \
	| awk '{ print $$2 }' > temp_data/src_datafiles.txt


list-asset-timestamps:
	cat temp_data/src_datafiles.txt | awk -F/ '{print $NF}' > temp_data/local_filenames.txt

	loopr -p -t --listfile temp_data/src_datafiles.txt --vartoken % \
	--cmd-string 'curl -I https://download.bls.gov% | scripts/parse_header.py' \
	> temp_data/head_commands.txt
	
	countup --from 1 --to `wc -l temp_data/local_filenames.txt` > temp_data/file_indices.txt

	loopr -p -t --listfile temp_data/local_filenames.txt --vartoken % \
	--cmd-string ''



download-files:
	echo 'placeholder'
	
