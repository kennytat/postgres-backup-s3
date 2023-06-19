#! /bin/sh
set -u # `-e` omitted intentionally, but i can't remember why exactly :'(
set -o pipefail

restore() {

	source ./env.sh

	s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

	if [ -z "$PASSPHRASE" ]; then
		file_type=".dump"
	else
		file_type=".dump.gpg"
	fi

	echo "Finding latest backup..."
	key_suffix=$(
		aws $aws_args s3 ls "${s3_uri_base}/${POSTGRES_DATABASE}" |
			sort |
			tail -n 1 |
			awk '{ print $4 }'
	)

	echo "Fetching backup from S3..."
	aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "${POSTGRES_DATABASE}${file_type}"

	if [ -n "$PASSPHRASE" ]; then
		echo "Decrypting backup..."
		gpg --decrypt --batch --passphrase "$PASSPHRASE" "${POSTGRES_DATABASE}.dump.gpg" >"${POSTGRES_DATABASE}.dump"
		rm "${POSTGRES_DATABASE}.dump.gpg"
	fi

	conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"

	echo "Restoring from backup..."
	pg_restore $conn_opts --clean --if-exists "${POSTGRES_DATABASE}.dump"
	rm "${POSTGRES_DATABASE}.dump"

	echo "Restore complete."
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
		restore
	done
else
	restore
fi
