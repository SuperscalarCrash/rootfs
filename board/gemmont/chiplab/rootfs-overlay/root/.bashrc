# Gemmont interactive Bash prompt.
case $- in
	*i*) ;;
	*) return ;;
esac

PS1="\[\e[36m\]\u\[\e[0m\]@\[\e[32m\]\h\[\e[0m\] \[\e[1m\]\[\e[33m\]\w \[\e[31m\]\$\[\e[0m\]\[\e[22m\] "
