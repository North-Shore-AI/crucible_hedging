import Config

# Disable CrucibleFramework.Repo - crucible_hedging doesn't need database persistence
config :crucible_framework, enable_repo: false
