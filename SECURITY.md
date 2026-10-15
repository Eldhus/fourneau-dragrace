# Security

Report a problem by a private security advisory on GitHub, not an issue.


## What holds what

- **The DigitalOcean token** lives in the owner's keyring and, encrypted, on the racer.
    - A guard alone may use it: up to a monthly cap, on sizes under an hourly ceiling.
    - Only in one region and image.
- **The site host** holds no DigitalOcean token.
    - Taken over, it can write false results and read the races, nothing more.
    - It runs unprivileged under systemd's sandbox.
- **The racer** has no port open but SSH.
    - The racer user reaches DigitalOcean only through the guard and cannot read the token.
- **Each race** gets its own SSH key and worker token, good only for its droplets while they live.
- **Builds** are made by GitHub Actions with its own token and run on both hosts.
    - So GitHub's account is in the trust.
    - Pull requests from forks are built and raced, never released.
