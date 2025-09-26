import random

def fibonacci(n):
    if n <= 1:
        return n
    return fibonacci(n - 1) + fibonacci(n - 2)

def simple_math(a, b):
    return a * b + a - b

def array_sum(arr):
    sum_val = 0
    for i in range(len(arr)):
        sum_val = sum_val + arr[i]
    return sum_val

def main():
    random.seed(42)
    res = 0

    # Function call overhead benchmark
    for i in range(10000):
        a = random.randint(1, 100)
        b = random.randint(1, 100)

        # Test simple function calls
        res = res + simple_math(a, b)

        # Test array function calls
        arr = [a, b, a + b, a - b, a * 2]
        res = res + array_sum(arr)

        # Test recursive calls (small numbers to avoid stack overflow)
        if i % 1000 == 0:
            res = res + fibonacci(a % 10)

    print(res)

main()