import random

def main():
    random.seed()
    x = random.randint(0, 10000000) % 100
    for i in range(100):
        print(x + i)

main()
