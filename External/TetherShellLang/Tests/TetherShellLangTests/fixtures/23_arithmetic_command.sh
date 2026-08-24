i=0
((i = i + 3))
echo "i=$i"
if ((i > 2)); then
  echo "gt2"
fi
if ((i > 10)); then
  echo "gt10"
else
  echo "le10"
fi
((i--))
echo "end:$i"
