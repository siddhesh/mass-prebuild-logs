#!/bin/bash

copr monitor mbp-gcc-16 --output-format text-row --fields "build_id,name,chroot,state" |
	awk '/failed$/{printf("%s,%s,%s\n", $1, $2, $3)}' |
	while read line; do
		IFS=',' read -r -a array <<< "$line"
		buildid=${array[0]}
		pkg=${array[1]}
		chroot=${array[2]}
		if [ ! -d $pkg-$buildid ]; then
			echo "$pkg ($buildid)"
			mkdir $pkg-$buildid
		fi
		if [ ! -d $pkg-$buildid/$chroot ]; then
			echo "    $chroot ($pkg:$buildid)"
			copr download-build -d $pkg-$buildid -r $chroot --logs $buildid
		fi
	done

echo "Waiting for downloads to finish..."
wait
echo "Done!"
