for w in foo bar baz; do
  case $w in
    foo) echo "got foo" ;;
    bar) echo "got bar" ;;
    *) echo "other: $w" ;;
  esac
done
