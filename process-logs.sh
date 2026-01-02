#!/bin/bash

is_pkgbug_includes() {
	if echo "$1" | tail -1 | grep -q "this is probably fixable by adding ‘#include"; then
		return 0
	elif echo "$1" | head -1 | grep -q "use of undeclared identifier 'uint64_t'"; then
		return 0
	fi
	return 1
}

is_pkgbug_bounds() {
	if echo "$1" | grep -q "\[-Werror=array-bounds=\]"; then
		return 0
	fi
	return 1
}

is_pkgbug_uninit() {
	if echo "$1" | grep -q "\[-Werror=maybe-uninitialized\]"; then
		return 0
	fi
	return 1
}

is_pkgbug_unused() {
	if echo "$1" | grep -q "\[-Werror=unused-but-set-variable=\]"; then
		return 0
	fi
	return 1
}

is_pkgbug_c23_str_const() {
	if echo "$1" | grep -q "\[-Werror=discarded-qualifiers\]"; then
		return 0
	elif echo "$1" | grep -q "\[-Wdiscarded-qualifiers\]"; then
		return 0
	elif echo "$1" | grep -q "assignment of read-only location"; then
		return 0
	fi
	return 1
}

is_pkgbug_proto_mismatch() {
	if echo "$1" | grep -q "too many arguments to function"; then
		return 0
	elif echo "$1" | grep -q "number of arguments doesn’t match prototype"; then
		return 0
	fi
	return 1
}

is_pkgbug_incompat_ptr() {
	if echo "$1" | grep -q "\[-Wincompatible-pointer-types\]$"; then
		return 0
	fi
	return 1
}

is_pkgbug_c_type() {
	if echo "$1" | grep -q "two or more data types in declaration specifiers"; then
		return 0
	elif echo "$1" | grep -q "expected identifier or ‘(’ before ‘_Generic’"; then
		return 0
	elif echo "$1" | grep -q "expected ‘{’ before ‘thread_local’"; then
		return 0
	elif echo "$1" | grep -q "cannot use keyword ‘false’ as enumeration constant"; then
		return 0
	elif echo "$1" | grep -q "‘bool’ cannot be defined via ‘typedef’"; then
		return 0
	elif echo "$1" | grep -q "conflicting types for"; then
		return 0
	fi
	return 1
}

is_pkgbug_cxx_type() {
	if echo "$1" | grep -q "redeclaration of C++ built-in type"; then
		return 0
	fi
	return 1
}

is_gcc_derivative() {
	if echo "$1" | grep -q "no matching function for call to ‘S2C(const char8_t \[2\])’"; then
		return 0
	fi
	return 1
}

find_error_line() {
	name=$1
	logfile=$2

	# A typical error line from gcc.
	error_lines=$(zgrep -A 3 ":[0-9]\+:[0-9]\+: error: " $logfile | head -4)

	t=
	if [ "x$error_lines" != "x" ]; then
		first_line=$(echo "$error_lines" | head -1)
		if is_pkgbug_bounds "$first_line"; then
			t="PKGBUG: bounds"
		elif is_pkgbug_incompat_ptr "$first_line"; then
			t="PKGBUG: incompat ptr"
		elif is_pkgbug_proto_mismatch "$first_line"; then
			t="PKGBUG: proto mismatch"
		elif is_pkgbug_c23_str_const "$first_line"; then
			t="PKGBUG: c23 str const"
		elif is_pkgbug_uninit "$first_line"; then
			t="PKGBUG: uninit"
		elif is_pkgbug_unused "$first_line"; then
			t="PKGBUG: unused"
		elif is_pkgbug_cxx_type "$first_line"; then
			t="PKGBUG: c++ type"
		elif is_pkgbug_c_type "$first_line"; then
			t="PKGBUG: c type"
		elif is_pkgbug_includes "$error_lines"; then
			t="PKGBUG: includes"
		elif is_gcc_derivative "$first_line"; then
			t="GCC_DERIVATIVE"
		else
			t="Inspect: compile error"
		fi
	fi

	if [ "x$t" != "x" ]; then
		echo "1,$name,all,$t,,\"$first_line\""
		return 0
	fi
	return 1
}

find_ice() {
	name=$1
	logfile=$2

	# Ignore ICE messages in the gcc build log.
	if [ "xname" == "xgcc" ]; then
		return 1
	fi

	error_line=$(zgrep ":[0-9]\+:[0-9]\+: internal compiler error:" $logfile | head -1)
	if [ "x$error_line" != "x" ]; then
		echo "1,$name,all,ICE,,\"$error_line\""
		return 0
	fi
	return 1
}

buildroot_failed() {
	if echo $1 | grep -q -e "/usr/bin/systemd-nspawn .*dnf5 builddep .*" \
				-e "/usr/bin/systemd-nspawn .*dnf5 .* --releasever [0-9]\+ install .*" \
				-e "error: Bad file:"; then
		return 0
	fi
	return 1
}

uninteresting_fails() {
	if [[ "$1" == "prep" || "$1" == "install" ]]; then
		return 0
	fi
	return 1
}

packaging_error() {
	logfile=$1
	how="$(zgrep -A 1 '^RPM build errors:$' $logfile)"
	if echo $how | grep -q -e "not found" -e " unpackaged" -e "Empty %files file"; then
		return 0
	fi
	return 1
}

comm -1 -3 <(sort .DONE) <(find -maxdepth 1 -type d | sed 's|^\./||' | grep -v '\.' | sed 's/-[0-9]\+$//' | sort) |
	while read name; do
		pkg=$(ls -d --color=none $name-[0-9]*)
		buildid=$(echo $pkg | sed 's/.*-\([0-9]\+\)$/\1/')

		# debugging.
		#if [ "$name" != "dovecot" ]; then
		#	continue
		#fi

		# Skip over builds that have not fully failed.
		if [ "$(copr status $buildid)" != "failed" ]; then
			continue
		elif grep -q "^$name$" .gcc15-fail; then
			echo "1,$name,all,Ignore: gcc15-fail,"
			continue
		fi

		result=
		finished=0
		while read chroot; do
			logfile=$pkg/$chroot/builder-live.log.gz
			if [[ ! -e $logfile ]]; then
				if [ -z "$result" ]; then
					result="Ignore: infra_issue"
					reason="infrastructure issue"
				fi
				continue
			fi

			failing_cmd="$(zgrep -A 1 "^ERROR: Command failed: $" $logfile | tail -1)"
			if [[ "x$failing_cmd" == "x" && -z $result ]]; then
				result="Ignore: infra_issue"
			elif buildroot_failed "$failing_cmd" && [ -z "$result" ]; then
				result="Ignore: buildroot_issue"
			elif zgrep -qi -e "Architecture is excluded: " -e "Architecture is not included" $logfile && [ -z "$result" ]; then
				result="Ignore: excluded_arch"
			fi

			if [ -n "$result" ]; then
				continue
			fi

			fail_stage=$(zgrep "Bad exit status from" $logfile | sed 's/.*(%\([^)]\+\))$/\1/' | tail -1)
			if uninteresting_fails $fail_stage; then
				result="Ignore: pkgfail_$fail_stage"
				continue
			elif packaging_error $logfile; then
				result="Ignore: packaging"
			elif [ -z "$result" ]; then # fallback result.
				result="Inspect: $fail_stage"
			fi

			# build logs we actually want to inspect more closely.
			if find_ice $name $logfile; then
				finished=1
				break
			elif find_error_line $name $logfile; then
				finished=1
				break
			fi
		done <<< "$(ls -1 --color=none $pkg)"
		# We didn't find a legitimate build issue.
		if [ "$finished" == "0" ]; then
			echo "1,$name,all,$result,"
		fi
	done
