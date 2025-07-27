#!/usr/bin/env sh

set -e

git tag > local.list
echo "Fetching available releases from GitLab..."
tags=$(glab release list -R gitlab-org/gitlab-runner | tail -n +3 | awk '{ print $1 }' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | grep -vf local.list)

echo "Available tags to process:"
echo "$tags"
echo ""

archs="x86_64 arm64 arm s390x ppc64le"
flavors="alpine3.21 alpine-latest ubuntu"

test_registry_access() {
    local test_image="registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:alpine3.21-arm64-v18.0.4"
    echo "Testing registry access with known image: $test_image"
    
    echo "1. Using skopeo inspect:"
    if skopeo inspect docker://$test_image 2>&1; then
        echo "✓ Skopeo can access the image"
    else
        echo "✗ Skopeo cannot access the image"
    fi
    
    echo ""
    echo "2. Using skopeo list-tags (first 5 tags):"
    skopeo list-tags docker://registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper 2>&1 | head -20
    
    echo ""
    echo "3. Testing with curl:"
    curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" https://registry.gitlab.com/v2/gitlab-org/gitlab-runner/gitlab-runner-helper/tags/list
}

test_registry_access
echo ""
echo "Starting sync process..."
echo ""

for tag in $tags
do
    if [ "$tag" != "v18.0.4" ]; then
        continue
    fi
    
    echo "Processing tag $tag..."
    
    tag_has_images=false
    
    for flavor in $flavors
    do
        if [ "$flavor" != "alpine3.21" ]; then
            continue
        fi
        
        echo "  Checking flavor $flavor..."
        flavor_has_images=false
        available_archs=""
        manifest_images=""
        
        for arch in $archs
        do
            arch_target=$arch
            if [ $arch_target = "x86_64" ]; then
                arch_target="amd64"
            fi
            
            source_image="registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:$flavor-$arch-$tag"
            dest_image="ghcr.io/morzan1001/gitlab-runner-helper:$flavor-$arch_target-$tag"
            
            echo "    Checking $arch: $source_image"
            
            if skopeo inspect --retry-times 3 docker://$source_image > /dev/null 2>&1; then
                echo "    ✓ Found image for $arch"
                available_archs="$available_archs $arch_target"
                manifest_images="$manifest_images $dest_image"
                flavor_has_images=true
                tag_has_images=true
                
                echo "    Copying $source_image..."
                echo "    To: $dest_image"
                skopeo copy --override-arch $arch_target \
                    docker://$source_image \
                    docker://$dest_image
                    
                if skopeo inspect docker://$dest_image > /dev/null 2>&1; then
                    echo "    ✓ Successfully copied"
                else
                    echo "    ⚠️  Warning: Could not verify copied image"
                fi
            else
                echo "    ✗ Image not found for $arch: $source_image"
                echo "    Debug info:"
                skopeo inspect docker://$source_image 2>&1 | head -5
            fi
        done
        
        if [ "$flavor_has_images" = true ]; then
            echo "  Creating manifest for $flavor-$tag"
            echo "  Available architectures: $available_archs"
            echo "  Images for manifest: $manifest_images"
            
            echo "  Waiting 5 seconds for images to be