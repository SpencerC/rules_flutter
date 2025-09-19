"""Public API for pub.dev package management in rules_flutter."""

load("//flutter/private:pub_repository.bzl", _pub_dev_repository = "pub_dev_repository")

# Re-export the repository rule
pub_dev_repository = _pub_dev_repository

def pub_deps(**kwargs):
    """Convenience macro for setting up multiple pub.dev dependencies.

    This macro allows you to declare multiple pub.dev packages at once.

    Args:
        **kwargs: Keyword arguments where keys are repository names and values
                 are either strings (package names) or dicts with package configuration.

    Example:
        pub_deps(
            fixnum = "fixnum",
            vector_math = {"package": "vector_math", "version": "2.1.4"},
        )
    """
    for repo_name, config in kwargs.items():
        if isinstance(config, str):
            # Simple case: just the package name
            pub_dev_repository(
                name = repo_name,
                package = config,
            )
        elif isinstance(config, dict):
            # Complex case: full configuration
            package = config.pop("package", repo_name)
            pub_dev_repository(
                name = repo_name,
                package = package,
                **config
            )
        else:
            fail("Invalid configuration for pub dependency {}: {}".format(repo_name, config))
