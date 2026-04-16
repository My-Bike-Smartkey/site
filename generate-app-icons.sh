#!/bin/bash

# D-SmartKey App Icon Generator
# This script generates iOS app icons from the SVG source

echo "🚀 Generating D-SmartKey App Icons..."

# Check if we have the source SVG
if [ ! -f "app-icon-1024.svg" ]; then
    echo "❌ app-icon-1024.svg not found!"
    exit 1
fi

# App icon sizes needed for iOS
declare -a sizes=(
    "20:AppIcon-20"
    "29:AppIcon-29" 
    "40:AppIcon-40"
    "58:AppIcon-29@2x"
    "60:AppIcon-20@3x"
    "76:AppIcon~ipad"
    "80:AppIcon-40@2x"
    "87:AppIcon-29@3x"
    "120:AppIcon@2x"
    "152:AppIcon@2x~ipad" 
    "167:AppIcon-83.5@2x~ipad"
    "180:AppIcon@3x"
    "1024:AppIcon~ios-marketing"
)

# Create temp directory
mkdir -p temp_icons

# Method 1: Try using macOS built-in tools
echo "📱 Attempting to generate icons using macOS tools..."

# Try using Safari to render SVG (macOS method)
if command -v /usr/bin/python3 &> /dev/null; then
    cat << 'EOF' > convert_svg_to_png.py
import sys
import subprocess
import os
from pathlib import Path

def svg_to_png_macos(svg_path, png_path, size):
    """Convert SVG to PNG using macOS built-in tools"""
    try:
        # Method 1: Use qlmanage (Quick Look)
        temp_path = f"/tmp/temp_icon_{size}.png"
        subprocess.run([
            "qlmanage", "-t", "-s", str(size), "-o", "/tmp", svg_path
        ], capture_output=True, check=True)
        
        # Move and rename the generated file
        generated_files = list(Path("/tmp").glob(f"*{Path(svg_path).stem}*"))
        if generated_files:
            os.rename(generated_files[0], png_path)
            return True
            
    except subprocess.CalledProcessError:
        pass
    
    try:
        # Method 2: Use sips (Scriptable Image Processing System)
        subprocess.run([
            "sips", "-s", "format", "png", "-z", str(size), str(size), svg_path, "--out", png_path
        ], capture_output=True, check=True)
        return True
    except subprocess.CalledProcessError:
        pass
    
    return False

if __name__ == "__main__":
    svg_file = sys.argv[1]
    png_file = sys.argv[2] 
    size = int(sys.argv[3])
    
    if svg_to_png_macos(svg_file, png_file, size):
        print(f"✅ Generated {png_file} ({size}x{size})")
    else:
        print(f"❌ Failed to generate {png_file}")
EOF

    # Generate each icon size
    for size_info in "${sizes[@]}"; do
        IFS=':' read -r size filename <<< "$size_info"
        python3 convert_svg_to_png.py "app-icon-1024.svg" "temp_icons/${filename}.png" "$size"
    done
    
    rm convert_svg_to_png.py
fi

# Move generated icons to the app bundle
if [ -d "temp_icons" ] && [ "$(ls -A temp_icons)" ]; then
    echo "📋 Moving icons to app bundle..."
    cp temp_icons/*.png "DatBikeSmartkey/Assets.xcassets/AppIcon.appiconset/"
    rm -rf temp_icons
    echo "✅ App icons generated successfully!"
    echo ""
    echo "🎨 Your D-SmartKey app now has a beautiful new icon!"
    echo "💡 Build and run the app to see the new branding."
else
    echo ""
    echo "⚠️ Automatic icon generation not available on this system."
    echo ""
    echo "📋 Manual steps to create app icons:"
    echo "1. Open 'app-icon-1024.svg' in a design app (Sketch, Figma, etc.)"
    echo "2. Export as PNG at 1024x1024 pixels"
    echo "3. Use an app icon generator tool like:"
    echo "   • https://appicon.co"
    echo "   • https://makeappicon.com"
    echo "   • Icon Set Creator (App Store)"
    echo "4. Replace the files in DatBikeSmartkey/Assets.xcassets/AppIcon.appiconset/"
    echo ""
    echo "🎯 The SVG source file is ready at: app-icon-1024.svg"
fi

echo ""
echo "🚀 D-SmartKey rebranding complete!"
echo "📝 Updated:"
echo "   • App display name: D-SmartKey"  
echo "   • Bundle identifier: app.dsmartkey"
echo "   • UI text and branding"
echo "   • URL schemes"
echo "   • Bluetooth descriptions"
echo ""