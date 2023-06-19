#! /bin/sh
set -eu
set -o pipefail

backup() {

	source ./env.sh

	echo "Creating backup of $POSTGRES_DATABASE database..."
	pg_dump --format=custom \
		-h $POSTGRES_HOST \
		-p $POSTGRES_PORT \
		-U $POSTGRES_USER \
		-d $POSTGRES_DATABASE \
		$PGDUMP_EXTRA_OPTS \
		>"${database}.dump"

	timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
	s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

	if [ -n "$PASSPHRASE" ]; then
		echo "Encrypting backup..."
		gpg --symmetric --batch --passphrase "$PASSPHRASE" "${database}.dump"
		rm "${database}.dump"
		local_file="${database}.dump.gpg"
		s3_uri="${s3_uri_base}.gpg"
	else
		local_file="${database}.dump"
		s3_uri="$s3_uri_base"
	fi

	echo "Uploading backup to $S3_BUCKET... aws $aws_args s3 cp $local_file $s3_uri"
	aws $aws_args s3 cp "$local_file" "$s3_uri"
	rm "$local_file"

	echo "Backup complete."

	if [ -n "$BACKUP_KEEP_DAYS" ]; then
		sec=$((86400 * BACKUP_KEEP_DAYS))
		date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
		backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

		echo "Removing old backups from $S3_BUCKET..."
		aws $aws_args s3api list-objects \
			--bucket "${S3_BUCKET}" \
			--prefix "${S3_PREFIX}" \
			--query "${backups_query}" \
			--output text |
			xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
		echo "Removal complete."
	fi
}

S3_PREFIX_DEFAULT="${S3_PREFIX}"
if [ -n "${POSTGRES_DATABASES}" ]; then
	IFS=','                    # split on .
	set -- $POSTGRES_DATABASES # split+glob with glob disabled.
	# Loop through the array and echo each element
	for database in "$@"; do
		echo processing database:: "${database}"
		export POSTGRES_DATABASE="${database}"
		if [ -n "${S3_PREFIX_DEFAULT}" ]; then
			export S3_PREFIX="${S3_PREFIX_DEFAULT}/${database}"
		else
			export S3_PREFIX="${database}"
		fi
		backup
	done
else
	backup
fi
