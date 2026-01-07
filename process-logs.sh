#!/bin/bash

logdir=$(mktemp -d /tmp/mpblog.XXXXXXXX)

cleanup() {
	if [ -d $logdir ]; then
		echo "Cleaning up $logdir"
		rm -rf $logdir
	fi
}

trap 'cleanup' 2
trap 'cleanup' 15

is_pkgbug_includes() {
	if echo "$1" | tail -1 | grep -q -e "this is probably fixable by adding ‘#include" \
		-e "use of undeclared identifier 'uint64_t'"; then
		return 0
	fi
	return 1
}

is_pkgbug_internals() {
	if echo "$1" | grep -q -e ".__.* is not a member of .std." \
		-e ".*__.* does not name a type"; then
		return 0
	fi
	return 1
}

is_pkgbug_bounds() {
	if echo "$1" | grep -q -e "\[-Werror=array-bounds=\]" \
		-e "\[-Werror=stringop-overflow=\]"; then
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
	if echo "$1" | grep -q -e "redeclaration of C++ built-in type" \
		-e "expected identifier before ‘concept’"; then
		return 0
	fi
	return 1
}

is_pkgbug_cxx_std() {
	if echo "$1" | grep -q -e "C++ versions less than C++.. are not supported" \
		-e "note: .* is only available from C++.. onwards" \
		-e "not match for .operator>>." \
		-e "ambiguous overload for .operator!=." \
		-e "‘concept’ does not name a type" \
		-e "has no member named .destroy." \
		-e " invalid conversion from .const char8_t*." \
		-e "'experimental' in namespace 'std' does not name a type"; then
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

find_cpp_error_line() {
	name=$1
	logfile=$2

	# A typical error line from gcc.
	error_lines=$(grep -A 3 ":[0-9]\+:[0-9]\+: error: " $logfile | head -4)

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
		elif is_pkgbug_cxx_std "$error_lines"; then
			t="PKGBUG: c++ std"
		elif is_pkgbug_c_type "$first_line"; then
			t="PKGBUG: c type"
		elif is_pkgbug_internals "$first_line"; then
			t="PKGBUG: internals"
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

find_other_error_line() {
	name=$1
	logfile=$2
	log_end="$(cat $logfile | tail -500)"
	error_line=

	if echo "$log_end" | grep -q -e "\*\*\* No rule to make target"; then
		t="PKGBUG: make error"
	elif echo "$log_end" | grep -A 1 -e "^Error: .*" | head -2 | grep -q ".*.f[^:]*:[0-9]\+:[0-9]\+:"; then
		t="PKGBUG: fortran"
		error_line=$(echo "$log_end" | grep -A 1 -e "^Error: .*" | head -1)
	elif echo "$log_end" | grep -A 1 -e "Assembler messages:$" | head -2 | grep -q "[eE]rror: "; then
		t="PKGBUG: assembler"
		error_line=$(echo "$log_end" | grep -A 1 -e 'Assembler messages:$' | sed -n 's/[Ee]rror: \(.*\)/\1/p')
	elif echo "$log_end" | grep -q -e "configure: error: "; then
		t="PKGBUG: configure"
		error_line=$(echo "$log_end" | sed -n 's/configure: error: \(.*\)/\1/p')
	elif echo "$log_end" | grep -B 1 -e "error: ld returned 1 exit status" | head -1 | grep -q "have you installed the static version of the atomic library"; then
		t="PKGBUG: static libatomic"
	fi

	if [ "x$t" != "x" ]; then
		echo "1,$name,all,$t,,\"$error_line\""
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

	error_line=$(grep ": internal compiler error:" $logfile | head -1)
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
	logend=$1
	how=$(echo "$logend" | grep -A 1 '^RPM build errors:$')
	if echo $how | grep -q -e "not found" -e " unpackaged" -e "Empty %files file"; then
		return 0
	fi
	return 1
}

#comm -1 -3 <(cut -d , -f 2 gcc16-prebuild-report.out | sort) \
#	<(find -maxdepth 1 -type d | sed 's|^\./||' | grep -v '\.' | sed 's/-[0-9]\+$//' | sort) |
find -maxdepth 1 -type d | sed 's|^\./||' | grep -v '\.' | sed 's/-[0-9]\+$//' | sort |
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

			# Decompress once.
			zcat $logfile > $logdir/$pkg.log
			logfile="$logdir/$pkg.log"
			logend=$(tail -200 $logfile)

			failing_cmd=$(echo "$logend" | grep -A 1 "^ERROR: Command failed: $" | tail -1)
			if [[ "x$failing_cmd" == "x" && -z $result ]]; then
				result="Ignore: infra_issue"
			elif buildroot_failed "$failing_cmd" && [ -z "$result" ]; then
				result="Ignore: buildroot_issue"
			elif echo "$logend" | grep -qi -e "Architecture is excluded: " -e "Architecture is not included" && [ -z "$result" ]; then
				result="Ignore: excluded_arch"
			fi

			if [ -n "$result" ]; then
				continue
			fi

			fail_stage=$(echo "$logend" | grep "Bad exit status from" $logfile | sed 's/.*(%\([^)]\+\))$/\1/' | tail -1)
			if uninteresting_fails $fail_stage; then
				result="Ignore: pkgfail_$fail_stage"
				continue
			elif packaging_error "$logend"; then
				result="Ignore: packaging"
			elif [ -z "$result" ]; then # fallback result.
				result="Inspect: $fail_stage"
			fi

			# build logs we actually want to inspect more closely.
			if find_ice $name $logfile; then
				finished=1
				break
			elif find_cpp_error_line $name $logfile; then
				finished=1
				break
			elif find_other_error_line $name $logfile; then
				finished=1
				break
			fi
		done <<< "$(ls -1 --color=none $pkg)"
		# We didn't find a legitimate build issue.
		if [ "$finished" == "0" ]; then
			echo "1,$name,all,$result,"
		fi
	done
