#!/usr/bin/env bash

set -e
shopt -s nullglob

# The archive to mirror
ARCHIVE=apt.pop-os.org/staging/master
# The components to mirror
COMPONENTS=(main)
# Distributions to mirror
DISTS=(
	bionic
	focal
	hirsute
	impish
)
# Architectures to mirror
ARCHS=(
	amd64
	i386
	src
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

    touch sync
    echo "# Automatically generated by build.sh" > build/sync

    for dist in "${DISTS[@]}"
    do
        for staging_pool in "build/mirror/${ARCHIVE}/pool/${dist}/"*/*
        do
            repo="$(basename "$(dirname "${staging_pool}")")"
            commit="$(basename "${staging_pool}")"
            echo -e "\e[1m$dist: $repo: $commit\e[0m"

            #TODO: make sure only one dsc exists
            staging_dsc="$(echo "${staging_pool}/"*".dsc")"
            #TODO: make sure only one version exists
            staging="$(grep "^Version: " "${staging_dsc}" | cut -d " " -f 2-)"
            echo "  - staging: ${staging}"

            release="$(grep "^${dist}/${repo}=" sync | cut -d "=" -f 3-)"
            if [ -n "${release}" ]
            then
                echo "  - release: ${release}"
            else
                echo "  - release: None"
            fi

            version="${release}"
            if dpkg --compare-versions "${staging}" gt "${release}"
            then
                if [ "$yes" == "1" ]
                then
                    echo "    Skipping prompt as --yes was provided"
                    answer="y"
                else
                    echo -n "    Do you want to sync '${staging}' to release? (y/N)"
                    read answer
                fi
                if [ "${answer}" == "y" ]
                then
                    echo "    Syncing '${staging}'"
                    version="${staging}"
                else
                    echo "    Not syncing, answer was '${answer}'"
                fi
            fi

            if [ -n "${version}" ]
            then
                echo "${dist}/${repo}=${commit}=${version}" >> build/sync
            fi
        done
    done

    mv -v build/sync sync
    echo -e "\e[1mSync complete, please commit changes\e[0m"
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
        if [ "${release}" == "${version}" ]
        then
            echo "    Version '${version}' already in release"
            cp -a "${release_pool}" "${partial_pool}"
        else
            if [ "${staging}" == "${version}" ]
            then
                echo "    Copying '${version}' from staging to release"
                cp -a "${staging_pool}" "${partial_pool}"
            else
                echo "    Failed to find '${version}' in staging or release" >&2
                exit 1
            fi
        fi
    done

    # Remove previous release dir
    rm -rf build/release

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
            "hirsute")
                dist_version="21.04"
                ;;
            "impish")
                dist_version="21.10"
                ;;
            *)
                echo "unknown dist '${dist}'" >@2
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

        pushd "${dists_dir}"
        set -x
        apt-ftparchive \
            -o "APT::FTPArchive::Release::Origin=pop-os-release" \
            -o "APT::FTPArchive::Release::Label=Pop!_OS Release" \
            -o "APT::FTPArchive::Release::Suite=${dist}" \
            -o "APT::FTPArchive::Release::Version=${dist_version}" \
            -o "APT::FTPArchive::Release::Codename=${dist}" \
            -o "APT::FTPArchive::Release::Architectures=${ARCHS}" \
            -o "APT::FTPArchive::Release::Components=${comp}" \
            -o "APT::FTPArchive::Release::Description=Pop!_OS Release ${dist} ${dist_version}" \
            release . > "Release"
        gpg --clearsign "${GPG_FLAGS[@]}" -o "InRelease" "Release"
        gpg -abs "${GPG_FLAGS[@]}" -o "Release.gpg" "Release"
        set +x
        popd
    done
    popd

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
