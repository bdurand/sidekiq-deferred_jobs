# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.1

### Changed

- Update code to override Sidekiq::Job if it is defined, otherwise override Sidekiq::Worker. This doesn't impact functionality, but is more compatible with modern Sidekiq versions since Sidekiq::Worker is discouraged since version 6.3.

## 1.0.0

### Added

- Add behavior to Sidekiq to allow deferring enqueing jobs until after a block of code finishes.
