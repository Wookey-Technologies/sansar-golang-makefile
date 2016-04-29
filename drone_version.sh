#!/bin/bash

set -e
set -x

if [[ ! -a version.go ]]; then
    # Service doesn't support info/version
    echo "Skipped saving version info because the service doesn't support info endpoint." 
    exit 0
fi

if [[ $DRONE ]]; then

    COMMIT_ID="$(git log --pretty=format:'%h' -n 1)" 
    NOW="$(date +'%Y-%m-%dT%H:%M:%SZ')"
    # This requires using v<X>.<Y>.<Z> style version numbers in the tags of 
    # commits. For now, all backend services will be 0.0.0. commitID is more 
    # important for our purposes anyway. 
    VERSION=$(git tag --contains $DRONE_COMMIT | grep "$DRONE_BRANCH" | tail -n1 | awk -F'v' '{print $2}') 
    if [[ ! $VERSION =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
        export VERSION="0.0.0";
    fi
    export CGO_ENABLED=0
    echo "commit_id:$COMMIT_ID, now:$NOW, version:$VERSION, cgo:$CGO_ENABLED, drone_commit:$DRONE_COMMIT, drone_build_number:$DRONE_BUILD_NUMBER, drone_branch:$DRONE_BRANCH, drone_image:$DRONE_DOCKER_IMAGE"
    # escape '/' in image to '\/'
    DOCKER_IMAGE_FOR_SED=$(echo $DRONE_DOCKER_IMAGE | sed 's/\//\\\//g')
    sed -i \
        -e "s/const softwareVersion string = .*$/const softwareVersion string = \""$VERSION"\"/" \
        -e "s/const commitID string = .*$/const commitID string = \""$COMMIT_ID"\"/" \
        -e "s/const buildID string = .*$/const buildID string = \""$DRONE_BUILD_NUMBER"\"/" \
        -e "s/const branch string = .*$/const branch string = \""$DRONE_BRANCH"\"/" \
        -e "s/const image string = .*$/const image string = \""$DOCKER_IMAGE_FOR_SED"\"/" \
        -e "s/const buildTime string = .*$/const buildTime string = \""$NOW"\"/" \
    version.go
    cat version.go
else
    echo "using default version.go, since this is a local build."
fi

