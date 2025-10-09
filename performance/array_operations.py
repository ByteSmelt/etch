import random

def main():
    random.seed(42)
    arr = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    sum_val = 0

    # Array access and modification benchmark
    for i in range(50000):
        idx = random.randint(0, 9)
        sum_val = sum_val + arr[idx]
        arr[idx] = (sum_val + arr[idx]) % 100000

        # Test array length operations
        if i % 1000 == 0:
            sum_val = (sum_val + 10) % 100000

    # Print final sum and array state
    print(sum_val)
    for i in range(len(arr)):
        print(arr[i])

main()