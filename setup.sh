echo "Setting up environment..."
sleep 1

if ! command -v direnv >/dev/null 2>&1
then
    echo 'direnv could not be found'
    echo
    echo 'Install with'
    echo '  sudo apt install direnv'
    echo 'or use your preferred package manager.'
    echo
    echo 'Then add the following to your ~/.bashrc'
    echo '  eval "$(direnv hook bash)"'
    echo 'Or if using zsh, to ~/.zshrc'
    echo '  eval "$(direnv hook zsh)"'
    echo
    echo 'Then run this script again.'
    echo
    exit 1
fi

mkdir -p ./tools

./setup_oss_cad_suite.sh

echo
echo 'All tools installed!'
echo 'Re-open the terminal to activate the env.'
echo
