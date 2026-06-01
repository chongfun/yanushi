# RBS Signatures

This directory contains the signatures used by Steep.

- `sig/app`: hand-written signatures for application code.
- `sig/shims`: narrow local signatures for Rails, gems, or dynamic APIs that are not covered well enough by collection signatures yet.
- `sig/rbs_rails`: optional generated Rails signatures if `rbs_rails` proves compatible with the current Rails version.

Use `bundle exec rbs prototype rb path/to/file.rb > sig/app/path/to/file.rbs` to scaffold a starting point, then refine it by hand.

Run type checks with:

```bash
bundle exec rbs validate
bundle exec steep check
```
