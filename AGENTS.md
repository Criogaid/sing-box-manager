# Independent implementation boundary

This directory is a new MIT project. Implementers must not read, copy, translate, refactor, or port code, tests, templates, comments, or Git history from the previous manager, from its upstream repository, or from any archive of either. Do not visit adjacent manager directories. Prior work is not a source for this project.

Implement only the behavioral requirements in REQUIREMENTS.md and interfaces in CONTRACTS.md. Public format/API documentation, command help from installed external executables, and deliberately synthetic fixtures are allowed. Do not copy external implementation source. Record actual public sources and their purpose in SOURCES.md. Only newly authored code and tests belong in this repository.

Use Bash 4.3+, jq, ordinary Linux tools, OpenSSL and qrencode. External sing-box and Caddy are invoked as processes; do not vendor their binaries, source or generated schema. Generate schema at runtime. JSON is handled by jq, not text substitutions. Users operate menus and semantic arguments, never jq or raw JSON editor prompts.

Keep responsibility boundaries small: common shell utilities; document storage and Caddy adapter; schema forms; node workflows; host operations; command dispatch. Avoid a rollback framework, dependency injection framework, lock service, or unused abstraction. Chinese user messages, docs and new comments; English function identifiers and test names.

Read-only commands must not restart services or modify active configuration. No SSH, production actions, pushes, releases or commits from workers. Test only inside temporary directories. The lead owns integration, commits and deployment.

Do not add an AGENTS.md to subdirectories. Each worker edits only its assigned files. Preserve other workers' changes and send contract conflicts to the lead.
