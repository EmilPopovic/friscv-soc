echo 'Installing OSS CAD Suite to ./tools/oss-cad-suite...'
sleep 1

if ! command -v wget >/dev/null 2>&1
then
    echo 'wget could not be found'
    echo
    echo 'Install with'
    echo '  sudo apt-get install wget'
    echo 'or use your preferred package manager.'
    echo
    exit 1
fi

if ! command -v tar >/dev/null 2>&1
then
    echo "tar could not be found"
    echo
    echo 'Install with'
    echo '  sudo apt install tar'
    echo 'or use your preferred package manager.'
    echo
    exit 1
fi

rm /tmp/oss-cad-suite.tgz || true
wget https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-07-06/oss-cad-suite-linux-x64-20260706.tgz -O /tmp/oss-cad-suite.tgz

rm -rf ./tools/oss-cad-suite

tar -zxvf /tmp/oss-cad-suite.tgz -C ./tools
rm /tmp/oss-cad-suite.tgz

echo 'Installed OSS CAD Suite.'
