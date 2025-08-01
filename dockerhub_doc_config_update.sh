#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Script that generates the `eclipse-temurin` config file for the official docker
# image github repo and the doc updates for the unofficial docker image repo.
# Process to update the official docker image repo 
# 1. Run ./update_all.sh to update all the dockerfiles in the current repo.
# 2. Submit PR to push the newly generated dockerfiles to the current repo.
# 3. After above PR is merged, git pull the latest changes.
# 4. Run this command
#
set -o pipefail

if [[ -z "$1" ]]; then
	official_docker_image_file="eclipse-temurin"
else
	official_docker_image_file="$1"
fi

supported_versions="8 11 17 21 24"
# set this to the latest LTS version
latest_version="21"
all_jvms="hotspot"
all_packages="jdk jre"

# Fetch the latest manifest from the official repo
wget -q -O official-eclipse-temurin https://raw.githubusercontent.com/docker-library/official-images/master/library/eclipse-temurin

oses="alpine ubuntu ubi windowsservercore-ltsc2025 nanoserver-ltsc2025 windowsservercore-ltsc2022 nanoserver-ltsc2022"
# The image which is used by default when pulling shared tags on linux e.g 8-jdk
default_linux_image="noble"
default_alpine_image=alpine-3.22

# Get the latest git commit of the current repo.
# This is assumed to have all the latest dockerfiles already.
gitcommit=$(git log | head -1 | awk '{ print $2 }')

print_official_text() {
	echo "$*" >> ${official_docker_image_file}
}

print_official_header() {
	print_official_text "# Eclipse Temurin OpenJDK images provided by the Eclipse Foundation."
	print_official_text
	print_official_text "Maintainers: George Adams <george.adams@microsoft.com> (@gdams),"
	print_official_text "             Stewart Addison <sxa@redhat.com> (@sxa)"
	print_official_text "GitRepo: https://github.com/adoptium/containers.git"
	print_official_text "GitFetch: refs/heads/main"
	print_official_text "Builder: buildkit"
}

function generate_official_image_tags() {
	# Generate the tags
	full_version=$(grep "JAVA_VERSION=" "${file}" | awk -F '=' '{ print $2 }')

	# Remove any `jdk` references in the version
	ojdk_version=$(echo "${full_version}" | sed 's/\(jdk-\)//;s/\(jdk\)//' | awk -F '_' '{ print $1 }')
	# Replace "+" with "_" in the version info as docker does not support "+"
	ojdk_version=${ojdk_version//+/_}
	
	case $os in
		"alpine") distro="alpine-"$(echo $dfdir | awk -F '/' '{ print $4 }' ) ;;
		"ubuntu") distro=$(echo $dfdir | awk -F '/' '{ print $4 }' ) ;;
		"ubi") distro=$(echo $dfdir | awk -F '/' '{ print $4 }' ) ;;
		"windows") distro=$(echo $dfdir | awk -F '/' '{ print $4 }' ) ;;
		*) distro=$os;;
	esac

	# Official image build tags are as below
	# 8-jre
	# 8u212-jdk
	full_ver_tag="${ojdk_version}-${pkg}"

	unset extra_shared_tags extra_ver_tags
	full_ver_tag="${full_ver_tag}-${distro}"
	# Commented out as this added the -hotspot tag which we don't need for temurin
	# extra_ver_tags=", ${ver}-${pkg}"
	
	ver_tag="${ver}-${pkg}-${distro}"
	all_tags="${full_ver_tag}, ${ver_tag}"
	# jdk builds also have additional tags
	if [ "${pkg}" == "jdk" ]; then
		jdk_tag="${ver}-${distro}"
		all_tags="${all_tags}, ${jdk_tag}"
		# make "eclipse-temurin:latest" point to newest supported JDK
		# shellcheck disable=SC2154
		if [ "${ver}" == "${latest_version}" ]; then
			if [ "${vm}" == "hotspot" ] && [ "${os}" != "alpine" ]; then
				extra_shared_tags=", latest"
			fi
		fi
	fi
	
	unset windows_shared_tags
	shared_tags=$(echo ${all_tags} | sed "s/-$distro//g")
	if [ $os == "windows" ]; then
		windows_version=$(echo $distro | awk -F '-' '{ print $1 }' )
		windows_version_number=$(echo $distro | awk -F '-' '{ print $2 }' )
		windows_shared_tags=$(echo ${all_tags} | sed "s/$distro/$windows_version/g")
		case $distro in
			nanoserver*) 
				constraints="${distro}, windowsservercore-${windows_version_number}"
				all_shared_tags="${windows_shared_tags}"
				;;
			*) 
				constraints="${distro}"
				all_shared_tags="${windows_shared_tags}, ${shared_tags}${extra_shared_tags}"
				;;
		esac
	else
	all_shared_tags="${shared_tags}${extra_shared_tags}"
	fi
}

function generate_official_image_arches() {
	# Generate the supported arches for the above tags.
	# Official images supports amd64, arm64vX, s390x, ppc64le amd windows-amd64
	if [ $os == "windows" ]; then
		arches="windows-amd64"
	else
		# shellcheck disable=SC2046,SC2005,SC1003,SC2086,SC2063
		arches=$(echo $(grep ') \\' ${file} | grep -v "*" | sed 's/) \\//g; s/|//g'))
		arches=$(echo ${arches} | sed 's/x86_64/amd64/g') # replace x86_64 with amd64
		arches=$(echo ${arches} | sed 's/ppc64el/ppc64le/g') # replace ppc64el with ppc64le
		arches=$(echo ${arches} | sed 's/arm64/arm64v8/g') # replace arm64 with arm64v8
		arches=$(echo ${arches} | sed 's/aarch64/arm64v8/g') # replace aarch64 with arm64v8
		arches=$(echo ${arches} | sed 's/armhf/arm32v7/g') # replace armhf with arm32v7
		# sort arches alphabetically
		arches=$(echo ${arches} | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ /, /g' | sed 's/, $//')
	fi
}

function print_official_image_file() {
	# Retrieve the latest manifest block
	official_manifest=$(sed -n "/${all_tags}/,/^$/p" official-eclipse-temurin)
	if [[ "${official_manifest}" != "" ]]; then
		# Retrieve the git commit sha from the official manifest
		official_gitcommit=$(echo "${official_manifest}" | grep 'GitCommit: ' | awk '{print $2}')
		# See if there are any changes between the two commit sha's
		if git diff "$gitcommit:$dfdir/$dfname" "$official_gitcommit:$dfdir/$dfname" >/dev/null 2>&1; then
			diff_count=$(git diff "$gitcommit:$dfdir/$dfname" "$official_gitcommit:$dfdir/$dfname" | wc -l)
			# check for diff in the entrypoint.sh file
			if [ -f "$dfdir/entrypoint.sh" ]; then
				diff_count=$((diff_count + $(git diff "$gitcommit:$dfdir/entrypoint.sh" "$official_gitcommit:$dfdir/entrypoint.sh" | wc -l)))
			fi
		else
			# Forcefully sets a diff if the file doesn't exist
			diff_count=1
		fi
	else
		# Forcefully sets a diff if a new dockerfile has been added
		diff_count=1
	fi
	
	if [[ ${diff_count} -eq 0 ]]; then
		commit="${official_gitcommit}"
	else
		commit="${gitcommit}"
	fi

	# Print them all
	{
	  if [[ "${distro}" == "${default_alpine_image}" ]]; then
		# Append -alpine to each shared tag
		all_tags="${all_tags}, ${all_shared_tags//, /-alpine, }-alpine"
	  fi
	  echo "Tags: ${all_tags}"
	  if [[ "${os}" == "windows" ]] || [[ "${distro}" == "${default_linux_image}" ]]; then
	  	echo "SharedTags: ${all_shared_tags}"
	  fi
	  echo "Architectures: ${arches}"
	  echo "GitCommit: ${commit}"
	  echo "Directory: ${dfdir}"
	  if [ $os == "windows" ]; then
	  	echo "Builder: classic"
		echo "Constraints: ${constraints}"
	  fi
	  echo ""
	} >> ${official_docker_image_file}
}

rm -f ${official_docker_image_file}
print_official_header

official_os_ignore_array=(clefos debian debianslim leap tumbleweed)

# Generate config and doc info only for "supported" official builds.
function generate_official_image_info() {
	# If it is an unsupported OS from the array above, return.
	for arr_os in "${official_os_ignore_array[@]}"; 
	do
		if [ "${os}" == "${arr_os}" ]; then
			return;
		fi
	done
	if [ "${os}" == "windows" ]; then
		distro=$(echo $dfdir | awk -F '/' '{ print $4 }' )
		# 20h2 and 1909 is not supported upstream
		if [[ "${distro}" == "windowsservercore-20h2" ]] || [[ "${distro}" == "windowsservercore-1909" ]] || [[ "${distro}" == "windowsservercore-ltsc2019" ]] ; then
			return;
		fi
		if [[ "${distro}" == "nanoserver-20h2" ]] || [[ "${distro}" == "nanoserver-1909" ]]; then
			return;
		fi
	fi
	# We do not push our nightly and slim images either.
	if [ "${build}" == "nightly" ] || [ "${btype}" == "slim" ]; then
		return;
	fi

	generate_official_image_tags
	generate_official_image_arches
	print_official_image_file
}

# Iterate through all the VMs, for each supported version and packages to
# generate the config file for the official docker images.
# Official docker images = https://hub.docker.com/_/adoptopenjdk
for vm in ${all_jvms}
do
	for ver in ${supported_versions}
	do
		print_official_text
		print_official_text "#------------------------------v${ver} images---------------------------------"
		for pkg in ${all_packages}
		do
			for os in ${oses}
			do
				for file in $(find . -name "Dockerfile" | grep "/${ver}" | grep "${pkg}" | grep "${os}" | sort -n)
				do
					# file will look like ./19/jdk/alpine/Dockerfile.releases.full
					# dockerfile name
					dfname=$(basename "${file}")
					# dockerfile dir
					dfdir=$(dirname $file | cut -c 3-)
					os=$(echo "${file}" | awk -F '/' '{ print $4 }')
					# build = release or nightly
					# build=$(echo "${dfname}" | awk -F "." '{ print $3 }')
					build="release"
					# btype = full or slim
					# btype=$(echo "${dfname}" | awk -F "." '{ print $4 }')
					build="full"
					generate_official_image_info
				done
			done
		done
	done
done
