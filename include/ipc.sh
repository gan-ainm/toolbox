#!/bin/bash

# ipc.sh - Toolbox module for message-based IPC
# Copyright (C) 2021-2022 Matthias Kruk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

__init() {
	if ! include "json" "queue"; then
		return 1
	fi

	declare -gxr  __ipc_root="/var/lib/toolbox/ipc"
	declare -gxr  __ipc_pubsub_root="$__ipc_root/pubsub"

	declare -gxir __ipc_version=1

	return 0
}

_ipc_encode() {
	local decoded="$1"

	if (( $# > 0 )); then
		base64 -w 0 <<< "$decoded"
	else
		base64 -w 0 < /dev/stdin
	fi
}

_ipc_decode() {
	local encoded="$1"

	if (( $# > 0 )); then
		base64 -d <<< "$encoded"
	else
		base64 -d < /dev/stdin
	fi
}

_ipc_sign() {
	local data="$1"

	local signature

	if ! signature=$(gpg --output - --detach-sig <(echo "$data") |
                                 _ipc_encode); then
		return 1
	fi

	echo "$signature"
	return 0
}

_ipc_verify() {
	local data="$1"
	local signature="$2"

	local result
	local err

	err=0

	if ! result=$(gpg --verify <(_ipc_decode <<< "$signature") <(echo "$data") 2>&1); then
		err=1
	fi

	echo "$result"
	return "$err"
}


_ipc_get() {
	local msg="$1"
	local field="$2"

	local value

	if ! value=$(_ipc_decode "$msg" | jq -e -r ".$field" 2>/dev/null); then
		return 1
	fi

	echo "$value"
	return 0
}

_ipc_msg_get() {
	local envelope="$1"
	local field="$2"

	local msg
	local value

	if ! msg=$(_ipc_get "$envelope" "message"); then
		return 1
	fi

	if ! value=$(_ipc_get "$msg" "$field"); then
		return 1
	fi

	echo "$value"
	return 0
}

_ipc_envelope_get_signature() {
	local envelope="$1"

	local data
	local signature

	if ! data=$(_ipc_get "$envelope" "message") ||
	   ! signature=$(_ipc_get "$envelope" "signature"); then
		return 2
	fi

	if ! _ipc_verify "$data" "$signature"; then
		return 1
	fi

	return 0
}

_ipc_envelope_verify() {
	local envelope="$1"

	local error

	if ! error=$(_ipc_envelope_get_signature "$envelope"); then
		log_error "Invalid signature on envelope"
		log_highlight "GPG output" <<< "$error" | log_error
		return 1
	fi

	return 0
}

_ipc_msg_version_supported() {
	local msg="$1"

	local -i version

	if ! version=$(ipc_msg_get_version "$msg"); then
		log_error "Could not get version from message"
		return 1
	fi

	if (( version != __ipc_version )); then
		log_error "Unsupported message version"
		return 1
	fi

	return 0
}

ipc_msg_validate() {
	local msg="$1"

	if ! _ipc_envelope_verify "$msg"; then
		return 1
	fi

	if ! _ipc_msg_version_supported "$msg"; then
		return 2
	fi

	return 0
}

_ipc_envelope_get_signature_info() {
	local msg="$1"

	local signature

	local sig_nameregex
	local sig_keyregex

	local sig_valid
	local sig_name
	local sig_email
	local sig_key

	sig_nameregex='"(.*) <([^>]*)>"'
	sig_keyregex='([0-9a-fA-F]{32,})'

	sig_valid="bad"
	sig_name="(unknown)"
	sig_email="(unknown)"
	sig_key="(unknown)"

	signature=$(_ipc_envelope_get_signature "$msg")
	case "$?" in
		0)
			sig_valid="good"
			;;
		1)
			sig_valid="bad"
			;;
		*)
			return 1
			;;
	esac

	if [[ "$signature" =~ $sig_nameregex ]]; then
		sig_name="${BASH_REMATCH[1]}"
		sig_email="${BASH_REMATCH[2]}"
	fi

	if [[ "$signature" =~ $sig_keyregex ]]; then
		sig_key="${BASH_REMATCH[1]}"
	fi

	echo "$sig_valid $sig_key $sig_email $sig_name"
	return 0
}

ipc_msg_dump() {
	local envelope="$1"

	local msg
	local version
	local signer_name
	local signer_email
	local signer_key

	local version_ok
	local signature_ok

	msg=$(_ipc_get "$envelope" "message")
	version=$(_ipc_msg_get "$envelope" "version")
	signer_name=$(ipc_msg_get_signer_name "$envelope")
	signer_email=$(ipc_msg_get_signer_email "$envelope")
	signer_key=$(ipc_msg_get_signer_key "$envelope")

	version_ok="no"
	signature_ok="no"

	if _ipc_msg_version_supported "$envelope"; then
		version_ok="yes"
	fi

	if _ipc_envelope_verify "$envelope"; then
		signature_ok="yes"
	fi

	cat <<EOF | log_highlight "ipc message"
Message version: $version [supported: $version_ok]
Signature valid: $signature_ok
Signer         : $signer_name <$signer_email>
Key fingerprint: $signer_key

$(_ipc_decode <<< "$msg" | jq .)
EOF

	return 0
}

_ipc_msg_new() {
	local source="$1"
	local destination="$2"
	local data="$3"
	local topic="$4"

	# For non-pubsub messages, the topic will be unset. This will
	# cause the topic not to show up in the JSON object because
	# json_object() skips empty fields.

	local encoded_data
	local timestamp
	local message
	local encoded_message
	local signature
	local envelope
	local encoded_envelope

	if ! encoded_data=$(_ipc_encode <<< "$data"); then
		log_error "Could not encode data"

	elif ! timestamp=$(date +"%s"); then
		log_error "Could not make timestamp"

	elif ! message=$(json_object "version"     "$__ipc_version" \
				     "source"      "$source"        \
				     "destination" "$destination"   \
				     "user"        "$USER"          \
				     "timestamp"   "$timestamp"     \
	                             "topic"       "$topic"         \
				     "data"        "$encoded_data"); then
		log_error "Could not make message"

	elif ! encoded_message=$(_ipc_encode "$message"); then
		log_error "Could not encode message"

	elif ! signature=$(_ipc_sign "$encoded_message"); then
		log_error "Could not make signature"

	elif ! envelope=$(json_object "message"   "$encoded_message" \
				      "signature" "$signature"); then
		log_error "Could not make envelope"

	elif ! encoded_envelope=$(_ipc_encode "$envelope"); then
		log_error "Could not encode envelope"

	else
		echo "$encoded_envelope"
		return 0
	fi

	return 1
}

ipc_msg_get_version() {
	local msg="$1"

	local version

	if ! version=$(_ipc_msg_get "$msg" "version"); then
		return 1
	fi

	echo "$version"
	return 0
}

ipc_msg_get_source() {
	local msg="$1"

	local src

	if ! src=$(_ipc_msg_get "$msg" "source"); then
		return 1
	fi

	echo "$src"
	return 0
}

ipc_msg_get_destination() {
	local msg="$1"

	local dst

	if ! dst=$(_ipc_msg_get "$msg" "destination"); then
		return 1
	fi

	echo "$dst"
	return 0
}

ipc_msg_get_user() {
	local msg="$1"

	local user

	if ! user=$(_ipc_msg_get "$msg" "user"); then
		return 1
	fi

	echo "$user"
	return 0
}

ipc_msg_get_timestamp() {
	local msg="$1"

	local timestamp

	if ! timestamp=$(_ipc_msg_get "$msg" "timestamp"); then
		return 1
	fi

	echo "$timestamp"
	return 0
}

ipc_msg_get_data() {
	local msg="$1"

	local data
	local data_raw

	if ! data=$(_ipc_msg_get "$msg" "data"); then
		return 1
	fi

	if ! data_raw=$(_ipc_decode <<< "$data"); then
		return 1
	fi

	echo "$data_raw"
	return 0
}

ipc_msg_get_topic() {
	local msg="$1"

	local topic

	if ! topic=$(_ipc_msg_get "$msg" "topic"); then
		return 1
	fi

	echo "$topic"
	return 0
}

ipc_msg_get_signature() {
	local msg="$1"

	local signature

	if ! signature=$(_ipc_get "$msg" "signature"); then
		return 1
	fi

	echo "$signature"
	return 0
}

ipc_msg_get_signer_name() {
	local msg="$1"

	local info
	local fields

	if ! info=$(_ipc_envelope_get_signature_info "$msg"); then
		return 1
	fi

	read -ra fields <<< "$info"
	echo "${fields[@]:3}"
	return 0
}

ipc_msg_get_signer_email() {
	local msg="$1"

	local info
	local fields

	if ! info=$(_ipc_envelope_get_signature_info "$msg"); then
		return 1
	fi

	read -ra fields <<< "$info"

	echo "${fields[2]}"
	return 0
}

ipc_msg_get_signer_key() {
	local msg="$1"

	local info
	local fields

	if ! info=$(_ipc_envelope_get_signature_info "$msg"); then
		return 1
	fi

	read -ra fields <<< "$info"

	echo "${fields[1]}"
	return 0
}

ipc_endpoint_open() {
	local name="$1"

	local endpoint

	if [[ -z "$name" ]]; then
		local self

		self="${0##*/}"
		name="priv/$USER.$self.$$.$(date +"%s").$RANDOM"
	fi

	endpoint="$__ipc_root/$name"

	if ! [ -d "$endpoint" ]; then
		if ! mkdir -p "$endpoint/subscriptions"; then
			return 1
		fi

		if ! queue_init "$endpoint/queue" ||
		   ! echo "$USER" > "$endpoint/owner" ||
		   ! chmod -R g+rwxs "$endpoint"; then
			if ! rm -rf "$endpoint"; then
				log_error "Could not clean up $endpoint"
			fi

			return 1
		fi
	fi

	echo "$name"
	return 0
}

ipc_endpoint_close() {
	local name="$1"

	local endpoint
	local subscription

	endpoint="$__ipc_root/$name"

	if ! queue_destroy "$endpoint/queue"; then
		return 1
	fi

	while read -r subscription; do
		if ! rm "$subscription/${name//\//_}"; then
			log_error "Could not unsubscribe $name from $subscription"
		fi
	done < <(find "$endpoint/subscriptions" -mindepth 1 -maxdepth 1 -type l)

	if ! rm -rf "$endpoint"; then
		return 1
	fi

	return 0
}

_ipc_endpoint_put() {
	local endpoint="$1"
	local msg="$2"

	local queue

	queue="$__ipc_root/$endpoint/queue"

	if ! queue_put "$queue" "$msg"; then
		return 1
	fi

	return 0
}

ipc_endpoint_send() {
	local source="$1"
	local destination="$2"
	local data="$3"
	local topic="$4"

	local msg

	if ! msg=$(_ipc_msg_new "$source" "$destination" "$data" "$topic"); then
		return 1
	fi

	if ! _ipc_endpoint_put "$destination" "$msg"; then
		return 1
	fi

	return 0
}

ipc_endpoint_recv() {
	local endpoint="$1"
	local -i timeout="${2--1}"

	local queue
	local msg

	queue="$__ipc_root/$endpoint/queue"

	if ! msg=$(queue_get "$queue" "$timeout"); then
		return 1
	fi

	echo "$msg"
	return 0
}

_ipc_endpoint_topic_create() {
	local topic="$1"

	if ! mkdir -p "$__ipc_pubsub_root/$topic"; then
		return 1
	fi

	return 0
}

_ipc_endpoint_topic_subscribe() {
	local endpoint="$1"
	local topic="$2"

	local topicdir
	local subscription

	topicdir="$__ipc_pubsub_root/$topic"
	subscription="$topicdir/${endpoint//\//_}"

	if ! ln -sf "$endpoint" "$subscription"; then
		return 1
	fi

	if ! ln -sfn "$topicdir" "$__ipc_root/$endpoint/subscriptions/$topic"; then
		rm -f "$subscription"
		return 1
	fi

	return 0
}

_ipc_endpoint_topic_get_subscribers() {
	local topic="$1"

	local subscription

	while read -r subscription; do
		local subscriber

		if ! subscriber=$(readlink "$subscription"); then
			continue
		fi

		echo "$subscriber"
	done < <(find "$__ipc_pubsub_root/$topic" -mindepth 1 -maxdepth 1 -type l)

	return 0
}

ipc_endpoint_subscribe() {
	local endpoint="$1"
	local topic="$2"

	if ! _ipc_endpoint_topic_create "$topic"; then
		return 1
	fi

	if ! _ipc_endpoint_topic_subscribe "$endpoint" "$topic"; then
		return 1
	fi

	return 0
}

ipc_endpoint_publish() {
	local endpoint="$1"
	local topic="$2"
	local message="$3"

	local subscriber

	if ! _ipc_endpoint_topic_create "$topic"; then
		return 1
	fi

	while read -r subscriber; do
		ipc_endpoint_send "$endpoint" "$subscriber" "$message" "$topic"
	done < <(_ipc_endpoint_topic_get_subscribers "$topic")

	return 0
}

_ipc_endpoint_foreach_message_helper() {
	local msg="$1"
	local endpoint="$2"
	local func="$3"
	local args=("${@:4}")

	"$func" "$endpoint" "$msg" "${args[@]}"
	return "$?"
}

ipc_endpoint_foreach_message() {
	local endpoint="$1"
	local func="$2"
	local args=("${@:3}")

	local queue

	queue="$__ipc_root/$endpoint/queue"

	if ! queue_foreach "$queue" _ipc_endpoint_foreach_message_helper \
	                   "$endpoint" "$func" "${args[@]}"; then
		return 1
	fi

	return 0
}
