import os

# Compare two .env files and report differences

def parse_env(filename):
    env = {}
    with open(filename) as f:
        for line in f:
            if line.strip() and not line.startswith('#'):
                k, _, v = line.strip().partition('=')
                env[k] = v
    return env

def diff_envs(env1, env2):
    keys = set(env1) | set(env2)
    for k in keys:
        v1, v2 = env1.get(k), env2.get(k)
        if v1 != v2:
            print(f"{k}: '{v1}' != '{v2}'")

if __name__ == "__main__":
    env_a = parse_env("env1.env")
    env_b = parse_env("env2.env")
    diff_envs(env_a, env_b)
