#!/usr/bin/env bash

set -e
shopt -s nullglob

# The archive to mirror
ARCHIVE=apt.pop-os.org/staging/master
# The components to mirror
COMPONENTS=(main)
# Distributions to mirror
DISTS=(
    impish
    jammy
    noble
)
# Distributions to keep packages from, even if removed from staging
DISTS_NO_REMOVE=(
    impish
)
# Architectures to mirror
ARCHS=(
    amd64
    i386
    arm64
    src
)
# A mapping of debian architechtures to output folder names
# Any architechtures listed here are required to build before a
# package can be released.
declare -A ARCHS_MAP=(
    [amd64]="amd64"
    [arm64]="arm64"
    [i386]="i386"
    [linux-any]="amd64 arm64"
    [any]="amd64 arm64 i386"
    [all]="amd64 arm64 i386"
)

GPG_FLAGS=(
    --batch --yes \
    --digest-algo sha512 \
)
if [ -n "${DEBEMAIL}" ]
then
    GPG_FLAGS+=(--local-user "${DEBEMAIL}")
fi

build="0"
ignore_binary="0"
pull="1"
sync="1"
yes="0"
for arg in "$@"
do
    case "$arg" in
        "--build")
            build="1"
            sync="0"
            ;;
        "--ignore-binary") # Allow package release even if binary failed to build
            ignore_binary="1"
            ;;
        "--yes")
            yes="1"
            ;;
        *)
            echo "unknown argument '$arg'" >&2
            echo "$0 [--build] [--yes]" >&2
            exit 1
            ;;
    esac
done

function dist_in_no_remove {
    local dist
    for dist in "${DISTS_NO_REMOVE[@]}"
    do
        if [ "$dist" = "$1" ]
        then
            return 0
        fi
    done
    return 1
}

function repo_pull {
    echo -e "\n\e[1mPulling...\e[0m"

    mkdir -p build

    echo "set base_path $(realpath build)" > build/mirror.list
    echo "set nthreads 64" >> build/mirror.list
    echo "set _autoclean 1" >> build/mirror.list
    echo "set run_postmirror 0" >> build/mirror.list

    for dist in "${DISTS[@]}"
    do
        for arch in "${ARCHS[@]}"
        do
            echo "deb-${arch} http://${ARCHIVE} ${dist} ${COMPONENTS[@]}" >> build/mirror.list
        done
    done

    echo "clean $ARCHIVE" >> build/mirror.list

    ./apt-mirror/apt-mirror build/mirror.list

    echo -e "\n\e[1mPull complete\e[0m"
}

function repo_sync {
    echo -e "\n\e[1mSyncing...\e[0m"

    summary=()
    total=0

    touch sync
    echo "# Automatically generated by build.sh" > build/sync

    for dist in "${DISTS[@]}"
    do
        dist_summary=()
        dist_total=0

        for staging_pool in "build/mirror/${ARCHIVE}/pool/${dist}/"*/*
        do
            repo="$(basename "$(dirname "${staging_pool}")")"
            echo -e "\e[1m$dist: $repo\e[0m"

            #TODO: make sure only one dsc exists
            staging_dsc="$(echo "${staging_pool}/"*".dsc")"
            if [[ -z $staging_dsc ]]; then
                echo -e "\e[1;33m  * ${repo} is missing a .dsc file. Packaging is incorrect. ${repo} cannot be released.\e[0m"
                continue
            fi
            #TODO: make sure only one version exists
            staging_version="$(grep "^Version: " "${staging_dsc}" | cut -d " " -f 2-)"
            staging_commit="$(basename "${staging_pool}")"
            echo "  - staging: ${staging_version}"

            version="$(grep "^${dist}/${repo}=" sync | cut -d "=" -f 3-)"
            commit="$(grep "^${dist}/${repo}=" sync | cut -d "=" -f 2)"
            if [ -n "${version}" ]
            then
                echo "  - release: ${version}"
            else
                echo "  - release: None"
            fi

            # Test if all architechtures in the debian/control file actually built. Set all_built to false if they havent all built.
            all_built=1
            declare -a test_archs
            builds_for=$(cat build/mirror/${ARCHIVE}/pool/${dist}/${repo}/*/*.dsc | grep "^Arch")
            for arch in $builds_for; do
                unset test_archs
                archs=( "${ARCHS_MAP[$arch]}" )
                for a in "${archs[@]}"; do
                    test_archs+=($a)
                done

                for a in "${test_archs[@]}"; do
                    if ! grep -qP "Filename: pool/${dist}/${repo}/" "build/mirror/${ARCHIVE}/dists/${dist}/main/binary-${a}/Packages"; then
                        all_built=0
                        echo -e "\e[1;33m  * ${repo} cannot be released because architecture ${a} in 'debian/control' did not build.\e[0m"
                        break
                    fi
                done

                if [ $all_built == 0 ]; then
                    break
                fi
            done

            # Now ask if we should sync if ( all architechtures built or --ignore-binary flag passed ) and a newer version is available
            if [ $((`expr $all_built + $ignore_binary`)) -ge 1 ] && dpkg --compare-versions "${staging_version}" gt "${version}"
            then
                if [ "$yes" == "1" ]
                then
                    echo "    Skipping prompt as --yes was provided"
                    answer="y"
                else
                    echo -n "    Do you want to sync '${staging_version}' to release? (y/N)"
                    read answer
                fi
                if [ "${answer}" == "y" ]
                then
                    dist_summary+=(
                        "  - ${repo}"
                        "    - New: \`${staging_version}\`"
                    )
                    if [ -n "${version}" ]
                    then
                        dist_summary+=(
                            "    - Old: \`${version}\`"
                            "    - https://github.com/pop-os/${repo}/compare/${commit}...${staging_commit}"
                        )
                    else
                        dist_summary+=(
                            "    - https://github.com/pop-os/${repo}/commit/${staging_commit}"
                        )
                    fi
                    total="$(expr "${total}" + 1)"

                    echo "    Syncing '${staging_version}'"
                    version="${staging_version}"
                    commit="${staging_commit}"
                else
                    echo "    Not syncing, answer was '${answer}'"
                fi
            fi

            if [ -n "${version}" ]
            then
                echo "${dist}/${repo}=${commit}=${version}" >> build/sync
            fi
        done

        dist_removed=()
        while read line
        do
            repo="$(echo "$line" | cut -d "=" -f 1 | cut -d "/" -f 2-)"
            if ! grep "^${dist}/${repo}=" build/sync > /dev/null
            then
                if dist_in_no_remove ${dist}
                then
                     echo $line >> build/sync
                else
                     dist_removed+=("${repo}")
                fi
            fi
        done < <(grep "^${dist}/" sync)

        for repo in "${dist_removed[@]}"
        do
            echo -e "\e[1m$dist: $repo\e[0m"
            echo "  - staging: none"
            version="$(grep "^${dist}/${repo}=" sync | cut -d "=" -f 3-)"
            echo "  - release: ${version}"

            if [ "$yes" == "1" ]
            then
                echo "    Skipping prompt as --yes was provided"
                answer="y"
            else
                echo -n "    Package removed, do you want to continue? (y/N)"
                read answer
            fi
            if [ "${answer}" != "y" ]
            then
                echo "    Exiting, answer was '${answer}'"
                exit 1
            fi

            dist_summary+=(
                "  - ${repo}"
                "    - Removed \`${version}\`"
            )
            total="$(expr "${total}" + 1)"
        done

        if [ -n "${dist_summary}" ]
        then
            summary+=(
                "- ${dist}"
                "${dist_summary[@]}"
            )
        fi
    done

    mv -v build/sync sync

    subject="Updated ${total} packages"
    echo -e "\e[1m${subject}:\e[0m"
    echo "${subject}" > build/message
    echo >> build/message
    for line in "${summary[@]}"
    do
        echo "$line" | tee -a build/message
    done

    echo -e "\e[1mSync complete, please commit changes:\e[0m"
    echo "git commit -F build/message -s sync"
}

function repo_build {
    echo -e "\e[1mBuilding...\e[0m"

    # Remove previous release data
    rm -rf build/release.partial

    # Create directory for previous repo
    mkdir -p build/release

    # Create temporary directory for updates
    mkdir -p build/release.partial

    # Copy according to sync file
    cat sync | while read line
    do
        if [[ "$line" == "#"* ]]
        then
            continue
        fi

        dist="$(echo "$line" | cut -d "=" -f 1 | cut -d "/" -f 1)"
        repo="$(echo "$line" | cut -d "=" -f 1 | cut -d "/" -f 2-)"
        commit="$(echo "$line" | cut -d "=" -f 2)"
        version="$(echo "$line" | cut -d "=" -f 3-)"

        echo -e "\e[1m$repo\e[0m ${dist}"
        echo "  - sync: ${version}"

        staging=""
        staging_pool="build/mirror/${ARCHIVE}/pool/${dist}/${repo}/${commit}"
        #TODO: make sure only one dsc exists
        staging_dsc="$(echo "${staging_pool}/"*".dsc")"
        if [ -n "${staging_dsc}" ]
        then
            #TODO: make sure only one version exists
            staging="$(grep "^Version: " "${staging_dsc}" | cut -d " " -f 2-)"
        fi
        if [ -n "${staging}" ]
        then
            echo "  - staging: ${staging}"
        else
            echo "  - staging: None"
        fi

        release=""
        release_pool="build/release/pool/${dist}/${repo}/${commit}"
        #TODO: make sure only one dsc exists
        release_dsc="$(echo "${release_pool}/"*".dsc")"
        if [ -n "${release_dsc}" ]
        then
            #TODO: make sure only one version exists
            release="$(grep "^Version: " "${release_dsc}" | cut -d " " -f 2-)"
        fi
        if [ -n "${release}" ]
        then
            echo "  - release: ${release}"
        else
            echo "  - release: None"
        fi

        partial_pool="build/release.partial/pool/${dist}/${repo}/${commit}"
        mkdir -p "$(dirname "${partial_pool}")"
        if [ "${staging}" == "${version}" ]
        then
            echo "    Copying '${version}' from staging to release"
            cp -a "${staging_pool}" "${partial_pool}"
        else
            if [ "${release}" == "${version}" ]
            then
                echo "    Keeping '${version}' already in release"
                cp -a "${release_pool}" "${partial_pool}"
            else
                echo "    Failed to find '${version}' in staging or release" >&2
                exit 1
            fi
        fi
    done

    # Create repo metadata
    #TODO: Use DISTS?
    pushd build/release.partial
    for dist_pool in pool/*
    do
        dist="$(basename "${dist_pool}")"
        #TODO: copy version from staging?
        case "${dist}" in
            "bionic")
                dist_version="18.04"
                ;;
            "focal")
                dist_version="20.04"
                ;;
            "impish")
                dist_version="21.10"
                ;;
            "jammy")
                dist_version="22.04"
                ;;
            "noble")
                dist_version="24.04"
                ;;
            *)
                echo "unknown dist '${dist}'" >&2
                exit 1
                ;;
        esac

        dists_dir="dists/${dist}"
        mkdir -p "${dists_dir}"

        # TODO: Use COMPONENTS?
        comp="main"
        comp_dir="${dists_dir}/${comp}"
        mkdir -p "${comp_dir}"

        for arch in "${ARCHS[@]}"
        do
            if [ "${arch}" == "src" ]
            then
                source_dir="${comp_dir}/source"
                mkdir -p "${source_dir}"

                set -x
                apt-ftparchive -qq sources "${dist_pool}" > "${source_dir}/Sources"
                gzip --keep "${source_dir}/Sources"
                set +x

                echo "Archive: ${dist}" > "${source_dir}/Release"
                echo "Version: ${dist_version}" >> "${source_dir}/Release"
                echo "Component: ${comp}" >> "${source_dir}/Release"
                echo "Origin: pop-os-release" >> "${source_dir}/Release"
                echo "Label: Pop!_OS Release" >> "${source_dir}/Release"
                echo "Architecture: source" >> "${source_dir}/Release"
            else
                binary_dir="${comp_dir}/binary-${arch}"
                mkdir -p "${binary_dir}"

                set -x
                apt-ftparchive --arch "${arch}" packages "${dist_pool}" > "${binary_dir}/Packages"
                gzip --keep "${binary_dir}/Packages"
                set +x

                echo "Archive: ${dist}" > "${binary_dir}/Release"
                echo "Version: ${dist_version}" >> "${binary_dir}/Release"
                echo "Component: ${comp}" >> "${binary_dir}/Release"
                echo "Origin: pop-os-release" >> "${binary_dir}/Release"
                echo "Label: Pop!_OS Release" >> "${binary_dir}/Release"
                echo "Architecture: ${arch}" >> "${binary_dir}/Release"
            fi
        done

        pushd ../..
        # Run appstream-generator on only four CPUs to prevent crashes
        set -x
        taskset --cpu-list 0-3 appstream-generator run "${dist}"
        set +x
        popd
        for comp in "${COMPONENTS[@]}"
        do
            set -x
            cp -r "../../export/data/${dist}/${comp}" "${dists_dir}/${comp}/dep11"
            gzip -dk "${dists_dir}/${comp}/dep11/"*.gz
            # Copy appstream media pool
            mkdir -p media
            cp -r "../../export/media/${dist}" "media/${dist}"
            set +x
        done

        pushd "${dists_dir}"
        set -x
        apt-ftparchive \
            -o "APT::FTPArchive::Release::Origin=pop-os-release" \
            -o "APT::FTPArchive::Release::Label=Pop!_OS Release" \
            -o "APT::FTPArchive::Release::Suite=${dist}" \
            -o "APT::FTPArchive::Release::Version=${dist_version}" \
            -o "APT::FTPArchive::Release::Codename=${dist}" \
            -o "APT::FTPArchive::Release::Architectures=${ARCHS[*]}" \
            -o "APT::FTPArchive::Release::Components=${comp}" \
            -o "APT::FTPArchive::Release::Description=Pop!_OS Release ${dist} ${dist_version}" \
            release . > "Release"
        gpg --clearsign "${GPG_FLAGS[@]}" -o "InRelease" "Release"
        gpg -abs "${GPG_FLAGS[@]}" -o "Release.gpg" "Release"
        set +x
        popd
    done
    popd

    # Remove previous release dir
    rm -rf build/release

    # Atomically update build/release
    mv -v build/release.partial build/release

    echo -e "\e[1mBuild complete\e[0m"
}

if [ "$pull" == "1" ]
then
    repo_pull
fi

if [ "$sync" == "1" ]
then
    repo_sync
fi

if [ "$build" == "1" ]
then
    repo_build
fi
