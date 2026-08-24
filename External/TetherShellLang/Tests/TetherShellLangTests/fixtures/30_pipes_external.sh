#@ cmdout: sort => 0 :: sorted-one\nsorted-two\n
#@ want: sort
printf 'b
a
' | sort
echo "status=$?"
