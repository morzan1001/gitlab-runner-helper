#!/usr/bin/env sh

set -e

git tag > local.list
echo "Fetching available releases from GitLab..."
tags=$(glab release list -R gitlab-org/gitlab-runner | tail -n +3 | awk '{ print $1 }' | grep -vf local.list)

echo "Available tags to process:"
echo "$tags"
echo ""

archs="x86_64 arm64 arm s390x ppc64le"
flavors="alpine3.21 alpine-latest ubuntu"

for tag in $tags
do
    echo "Processing tag $tag..."
    
    tag_has_images=false
    
    for flavor in $flavors
    do
        echo "  Checking flavor $flavor..."
        flavor_has_images=false
        available_archs=""
        
        for arch in $archs
        do
            arch_target=$arch
            if [ $arch_target = "x86_64" ]; then
                arch_target="amd64"
            fi
            
            source_image="registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:$flavor-$arch-$tag"
            
            if skopeo inspect docker://$source_image > /dev/null 2>&1; then
                echo "    ✓ Found image for $arch"
                available_archs="$available_archs $arch_target"
                flavor_has_images=true
                tag_has_images=true
                
                echo "    Copying $source_image..."
                skopeo copy --override-arch $arch_target --dest-creds=":$GITHUB_TOKEN" \
                    docker://$source_image \
                    docker://ghcr.io/morzan1001/gitlab-runner-helper:$flavor-$arch_target-$tag
            else
                echo "    ✗ Image not found for $arch: $source_image"
            fi
        done
        
        if [ "$flavor_has_images" = true ]; then
            echo "  Creating manifest for $flavor-$tag with archs:$available_archs"
            
            platforms=""
            for arch in $available_archs; do
                if [ -n "$platforms" ]; then
                    platforms="$platforms,linux/$arch"
                else
                    platforms="linux/$arch"
                fi
            done
            
            manifest-tool push from-args \
                --platforms $platforms \
                --template ghcr.io/morzan1001/gitlab-runner-helper:$flavor-ARCH-$tag \
                --target ghcr.io/morzan1001/gitlab-runner-helper:$flavor-$tag
        else
            echo "  ✗ No images found for flavor $flavor, skipping manifest creation"
        fi
    done
    
    if [ "$tag_has_images" = true ]; then
        echo "Creating release $tag..."
        gh release create $tag --generate-notes --notes "Synchronized GitLab Runner Helper images for version $tag"
        git tag $tag
        echo "✓ Successfully processed tag $tag"
    else
        echo "✗ No images found for tag $tag, skipping release creation"
    fi
    
    echo ""
done

echo "Sync completed."