#!/bin/bash

__init() {
	local script_name
	local timestamp

	if ! script_name=$(basename "$BASH_ARGV0"); then
		echo "Could not determine script name" 1>&2
		return 1
	fi

	if ! timestamp=$(date +"%Y-%m-%d.%H:%M"); then
		echo "Could not make timestamp for the log name" 1>&2
		return 1
	fi

	declare -xgri __log_debug=3
	declare -xgri __log_info=2
	declare -xgri __log_warning=1
	declare -xgri __log_error=0

	declare -xgi __log_verbosity="$__log_warning"
	declare -xgr __log_path="$TOOLBOX_HOME/log"
	declare -xgr __log_file="$__log_path/$timestamp.$script_name.$$.log"

	if ! mkdir -p "$__log_path"; then
		return 1
	fi

	return 0
}

log_set_verbosity() {
	local verb

	verb="$1"

	if (( verb < __log_error )); then
		verb="$__log_error"
	elif (( verb > __log_debug )); then
	        verb="$__log_debug"
	fi

	__log_verbosity="$verb"

	return 0
}

log_get_verbosity() {
	echo "$__log_verbosity"
}

log_write() {
	local level
	local prefix
	local line

	level="$1"
	prefix="$2"

	if (( __log_verbosity < level )); then
		return 0
	fi

	if (( $# > 2 )); then
		for line in "${@:3}"; do
			if ! date +"%F %T %z $prefix $line" >> "$__log_file"; then
				echo "Could not write to $__log_file" 1>&2
				return 1
			fi
		done
	else
		while read -r line; do
			log_write "$level" "$prefix" "$line"
		done
	fi

	return 0
}

log_stacktrace() {
	local i
	local indent

	echo "Stacktrace:"
	indent="  "

	for (( i = "${#FUNCNAME[@]}"; i > 1; )); do
		((i--))
		echo "$indent${BASH_SOURCE[$i]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}"
		ident+=" "
	done

	return 0
}

log_highlight() {
	local tag

	tag="$1"

	echo "===== BEGIN $tag ====="
	if (( $# > 1 )); then
		local arg

		for arg in "${@:2}"; do
			echo "$arg"
		done
	else
		cat /dev/stdin
	fi
	echo "===== END $tag ====="
}

log_debug() {
	local dbgtag
	local line

	dbgtag="${BASH_SOURCE[1]}:${BASH_LINENO[1]} ${FUNCNAME[1]}:"

	log_write "$__log_debug" "[DBG] $dbgtag" "$@"
}

log_info() {
	log_write "$__log_info" "[INF]" "$@"
}

log_warn() {
	log_write "$__log_warning" "[WRN]" "$@"
}

log_error() {
	log_write "$__log_error" "[ERR]" "$@"
}
