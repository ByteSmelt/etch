# types.nim
# Common types used across the Etch implementation

type
  Pos* = object
    line*, col*: int
    filename*: string


# Branch prediction hints for performance optimization
template likely*(cond: untyped): untyped =
  when defined(gcc) or defined(clang):
    {.emit: "__builtin_expect((" & astToStr(cond) & "), 1)".}
    cond
  else:
    cond


template unlikely*(cond: untyped): untyped =
  when defined(gcc) or defined(clang):
    {.emit: "__builtin_expect((" & astToStr(cond) & "), 0)".}
    cond
  else:
    cond
