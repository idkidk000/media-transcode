#!/bin/bash

IFS=' '

root_directories='/mnt/hosts/nas/media/tv/ /mnt/hosts/nas/media/movies/ '
min_file_size=$((1024**3)) #1 GiB - smallest file size to consider for transcoding
max_file_bit_rate=$((1024**3*6*8/90/60)) #6 GiB * 8 bits per byte / 90 mins / 60 secs per min = 9320 Kibps
max_video_bit_depth=8
allowed_video_codecs='avc1 V_MPEG4/ISO/AVC V_VP8'
ffmpeg_timeout_multiplier=5 #multiply by video duration to get ffmpeg timeout
ffmpeg_timeout_minimum=$((60*1)) #1 minute - in case $min_file_size is very small
ffmpeg_timeout_maximum=$((60*60*6)) #6 hours
transcode_directory='/mnt/transcode/'

target_file_bitrate=$((1024**3*8*5/90/60)) #5 GiB * 8 bits per byte / 90 mins / 60 secs per min = 7767 Kibps

kodi_url='http://127.0.0.1:8080/jsonrpc'
kodi_json_scan='{"jsonrpc":"2.0","id":1,"method":"VideoLibrary.Scan"}'

log_file='/mnt/hosts/nas/files/scripts/media/media-transcode.log'
history_file='/mnt/hosts/nas/files/scripts/media/media-transcode.history'

required_binaries='find mktemp mediainfo xpath awk timeout ffmpeg curl cat'

for required_binary in $required_binaries
do
	which "$required_binary" > /dev/null
	if [ $? -ne 0 ]
	then
		echo "$required_binary was not found. Exiting"
		exit 1
	fi
done

if [ ! -f "$log_file" ]
then
	echo "Result,Timestamp,Bitrate,Bitdepth,Codec,Duration,Filename" > "$log_file"
fi

rm -rf "$transcode_directory*"

while [ true ]
do
	for root_directory in $root_directories
	do
		IFS='
	'
		for file in $(find $root_directory -type f -size +${min_file_size}c -exec ls -S1 {} +) #sort by size descending
		do
			IFS=' '
			# don't start a new transcode between 22:00 and 07:00
			while [ $(date +%k) -ge 22 ] || [ $(date +%k) -lt 7 ]
			do
				sleep 15m
			done
			echo $file
			mediainfo_file=$(mktemp)
			# echo $mediainfo_file
			mediainfo "$file" --Output=XML > "$mediainfo_file"
			# ints as strings. convert further down
			file_bit_rate=$(xpath -q -e 'MediaInfo/media/track[@type="General"]/OverallBitRate/text()' $mediainfo_file )
			file_duration=$(xpath -q -e 'MediaInfo/media/track[@type="General"]/Duration/text()' $mediainfo_file )
			file_frames=$(xpath -q -e 'MediaInfo/media/track[@type="General"]/FrameCount/text()' $mediainfo_file )
			file_size=$(xpath -q -e 'MediaInfo/media/track[@type="General"]/FileSize/text()' $mediainfo_file )
			video_bit_depth=$(xpath -q -e 'MediaInfo/media/track[@type="Video"]/BitDepth/text()' $mediainfo_file )
			
			file_frame_rate=$(xpath -q -e 'MediaInfo/media/track[@type="General"]/FrameRate/text()' $mediainfo_file ) #want to preserve decimals - keep as string
			video_codec=$(xpath -q -e 'MediaInfo/media/track[@type="Video"]/CodecID/text()' $mediainfo_file )
			
			rm "$mediainfo_file"
			
			#convert to integers so that we can use them for maths
			file_bit_rate=$(echo $file_bit_rate | awk '{print int($1+0.5)}')
			file_duration=$(echo $file_duration | awk '{print int($1+0.5)}')
			file_frames=$(echo $file_frames | awk '{print int($1+0.5)}')
			file_size=$(echo $file_size | awk '{print int($1+0.5)}')
			if [ "$video_bit_depth" = '' ] # not all formats (webm) expose the bit depth and mediainfo doesn't seem to return a useful exit code
			then
				video_bit_depth=8
			else
				video_bit_depth=$(echo $video_bit_depth | awk '{print int($1+0.5)}')
			fi
			
			echo "Rate $((file_bit_rate/1024/1024))Mibps / $((file_bit_rate/1024))Kibps"
			echo "Max  $(($max_file_bit_rate/1024/1024))Mibps / $(($max_file_bit_rate/1024))Kibps"
			echo "$video_bit_depth bit $video_codec"
			echo "$(($file_duration/60))m / ${file_duration}s"
			echo "$file_frames frames @ ${file_frame_rate}fps"
			echo "$((file_size/1024/1024/1024))GiB / $((file_size/1024/1024))MiB"
			
			echo " $allowed_video_codecs " | grep -q " $video_codec "
			if [ $? -eq 0 ] #contains operator
			then
				bad_codec=false
			else 
				bad_codec=true
			fi
			
			if [ $file_bit_rate -gt $max_file_bit_rate ] || [ $video_bit_depth -gt $max_video_bit_depth ] || [ $bad_codec = true ]
			then
				
				previously_transcoded=false
				for history_item in $(cat "$history_file" 2> /dev/null)
				do
					if [ "$history_item" = "$file" ]
					then
						previously_transcoded=true
						break
					fi
				done
				
				if [ $previously_transcoded = true ]
				then
					echo "Error: File has already been transcoded"
					echo "repeat,$(date +%Y-%m-%d-%H:%M:%S),$file_bit_rate,$video_bit_depth,$video_codec,$file_duration,$file" >> "$log_file"
				else
					echo "Transcoding"
					timeout=$(($file_duration*$ffmpeg_timeout_multiplier))
					if [ $timeout -le $ffmpeg_timeout_minimum ]
					then
						timeout=$ffmpeg_timeout_minimum
					elif [ $timeout -ge $ffmpeg_timeout_maximum ]
					then
						timeout=$ffmpeg_timeout_maximum
					fi
					filename=$(basename "$file")
					#ffmpeg's built-in -timeout is finicky
					timeout --foreground $timeout ffmpeg -loglevel warning -hide_banner -stats -y -i "$file" -bitrate $(($target_file_bitrate/1024)) -c:v libx264 -preset slow -tune film -c:a copy -threads 0 "$transcode_directory${filename%.*}.mkv"
					if [ $? -eq 0 ]
					then
						echo "Transcode sucessful"
						rm "$file"
						mv "$transcode_directory${filename%.*}.mkv" "${file%.*}.mkv"
						echo "transcoded,$(date +%Y-%m-%d-%H:%M:%S),$file_bit_rate,$video_bit_depth,$video_codec,$file_duration,$file" >> "$log_file"
						echo "$file" >> "$history_file"
						curl -X POST $kodi_url -d $kodi_json_scan 
					else
						echo "Transcode failed"
						rm "$transcode_directory${filename%.*}.mkv"
						echo "failed,$(date +%Y-%m-%d-%H:%M:%S),$file_bit_rate,$video_bit_depth,$video_codec,$file_duration,$file" >> "$log_file"
					fi
				fi
			else
				echo "No need to transcode"
				echo "skipped,$(date +%Y-%m-%d-%H:%M:%S),$file_bit_rate,$video_bit_depth,$video_codec,$file_duration,$file" >> "$log_file"
			fi
		done
		IFS=' '
	done
	sleep 60m
done