code='echo from-eval'
eval "$code"
eval "echo eval-$((1 + 1))"
vname=RESULT
RESULT=42
eval "echo indirect:\$$vname"
