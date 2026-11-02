# Build 14 checklist example

Requires the verified local Build 14 development source (`7bd3660` or later with
these fixes). It is not a newly distributed build. For Build 13 or an unknown
reader, use `review-example.md` and keep commands outside tasks.

- [ ] Verify `echo a | cat` prints `a`.
- [x] Verify `echo b | cat` prints `b`.
- [ ] Run the following commands and check their output.
  ```sh
  echo a | cat
  echo b | cat
  ```
