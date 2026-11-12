# Dockerfile

The Dockerfile is for production, not development. Railway builds the image from it. To build and run it by hand:

```bash
docker build -t code_gym_rails .
docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name code_gym_rails code_gym_rails
```

For a containerized development environment, see the Rails guide on Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

## Stages

- `base` holds the runtime packages and the production environment variables.
- `build` is thrown away. It adds the packages needed to compile gems, installs the gems, copies the application, installs Prettier for `CodeFormat::Javascript`, precompiles bootsnap and precompiles assets, so none of that weight reaches the final image.
- The final stage copies the gems and the application out of `build`, then runs as a non-root user (uid 1000) that owns only the runtime folders (`db`, `log`, `storage`, `tmp`).

## Startup

`bin/docker-entrypoint` prepares the database. The default command starts the server through Thruster on port 80, and a deploy can override it.

## Comments

The two lines at the top (`syntax` and `check`) are parser directives. `bin/comment-check` does not count them, because they only work as the first lines of the file.
