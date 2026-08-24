for a in 1 2 3; do
  for b in a b c; do
    if [ "$b" = "b" ]; then
      break
    fi
    echo "$a$b"
  done
done
echo end
