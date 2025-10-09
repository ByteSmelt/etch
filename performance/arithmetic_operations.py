import random

def main():
    random.seed(42)
    result = 0

    # Arithmetic operations benchmark
    for _ in range(100000):
        a = random.randint(1, 100)
        b = random.randint(1, 100)

        # Mix of operations to test different arithmetic paths
        sum = a + b
        diff = a - b
        prod = a * b % 1000
        quotient = a // (b % 10 + 1)

        result = (result % 1000 + sum % 1000) % 10000
        result = (result % 1000 + diff % 1000) % 10000
        result = (result % 1000 + prod % 1000) % 10000
        result = (result % 1000 + quotient % 1000) % 10000

    print(result)

main()
