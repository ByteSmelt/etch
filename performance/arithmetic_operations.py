import random

def main():
    random.seed(42)
    result = 0

    # Arithmetic operations benchmark
    for i in range(100000):
        a = random.randint(1, 1000)
        b = random.randint(1, 1000)

        # Mix of operations to test different arithmetic paths
        result = result + a + b
        result = result - a * b % 7
        result = result + a // (b % 10 + 1)  # Avoid division by zero
        result = result * 2

    print(result)

main()