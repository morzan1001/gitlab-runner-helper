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
            dest_image="ghcr.io/morzan1001/gitlab-runner-helper:$flavor-$arch_target-$tag"
            
            echo "    Checking $arch: $source_image"
            
            if skopeo inspect --raw docker://$source_image 2>/dev/null | jq -e '.manifests' > /dev/null 2>&1; then
                echo "    ✓ Found multi-arch manifest for $arch"
                
                manifest_arch=$(skopeo inspect --raw docker://$source_image 2>/dev/null | jq -r '.manifests[0].platform.architecture')
                
                if [ "$manifest_arch" = "$arch_target" ] || ([ "$arch" = "x86_64" ] && [ "$manifest_arch" = "amd64" ]); then
                    available_archs="$available_archs $arch_target"
                    flavor_has_images=true
                    tag_has_images=true
                    
                    echo "    Copying $source_image (contains $manifest_arch)..."
                    echo "    To: $dest_image"
                    
                    skopeo copy --all \
                        docker://$source_image \
                        docker://$dest_image
                    
                    if skopeo inspect docker://$dest_image > /dev/null 2>&1; then
                        echo "    ✓ Successfully copied"
                    else
                        echo "    ⚠️  Warning: Could not verify copied image"
                    fi
                else
                    echo "    ⚠️  Architecture mismatch: expected $arch_target, found $manifest_arch"
                fi
            else
                if skopeo inspect docker://$source_image > /dev/null 2>&1; then
                    echo "    ✓ Found single-arch image for $arch"
                    available_archs="$available_archs $arch_target"
                    flavor_has_images=true
                    tag_has_images=true
                    
                    echo "    Copying $source_image..."
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
                fi
            fi
        done
        
        if [ "$flavor_has_images" = true ]; then
            echo "  Creating manifest for $flavor-$tag"
            echo "  Available architectures: $available_archs"
            
            echo "  Waiting 5 seconds for images to be fully available..."
            sleep 5
            
            platforms=""
            for arch in $available_archs; do
                arch_clean=$(echo $arch | xargs)
                if [ -n "$platforms" ]; then
                    platforms="$platforms,linux/$arch_clean"
                else
                    platforms="linux/$arch_clean"
                fi
            done
            
            echo "  Manifest platforms: $platforms"
            
            manifest-tool push from-args \
                --platforms $platforms \
                --template ghcr.io/morzan1001/gitlab-runner-helper:$flavor-ARCH-$tag \
                --target ghcr.io/morzan1001/gitlab-runner-helper:$flavor-$tag \
                --ignore-missing || echo "  ⚠️  manifest-tool reported warnings"
                
            echo "  Verifying manifest..."
            if skopeo inspect docker://ghcr.io/morzan1001/gitlab-runner-helper:$flavor-$tag > /dev/null 2>&1; then
                echo "  ✓ Manifest created successfully"
            else
                echo "  ⚠️  Could not verify manifest"
            fi
        else
            echo "  ✗ No images found for flavor $flavor, skipping manifest creation"
        fi
    done
    
    if [ "$tag_has_images" = true ]; then
        echo "Creating release $tag..."
        gh release create $tag --generate-notes --notes "Synchronized GitLab Runner Helper images for version $tag" || echo "Release $tag already exists"
        git tag $tag || echo "Tag $tag already exists"
        echo "✓ Successfully processed tag $tag"
    else
        echo "✗ No images found for tag $tag, skipping release creation"
    fi
    
    echo ""
done

echo "Sync completed."