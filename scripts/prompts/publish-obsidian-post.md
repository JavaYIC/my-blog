# Obsidian to Hugo/FixIt Publisher

You are publishing one Obsidian note into this Hugo blog using the FixIt theme.

Follow these rules exactly:

1. Do not modify the original Obsidian vault.
2. Do not modify files under `.publish-staging` except when explicitly writing metadata.
3. Create or update exactly one Hugo post under `content/posts/<slug>/index.md`.
4. Copy every referenced image from `.publish-staging/attachments` into the post bundle directory.
5. Convert Obsidian image embeds such as `![[image.jpg]]` or `![[image.jpg|caption]]` into Hugo-compatible Markdown image links.
6. Use YAML front matter.
7. Set `draft: false`.
8. Do not use `draft` as a tag or category.
9. Preserve the author's original wording unless a small formatting change is needed for Hugo compatibility.
10. Do not run `git commit` or `git push`. The wrapper script handles Git.

Front matter expectations:

- `title`: infer from existing front matter, first heading, or filename.
- `date`: preserve existing date when available; otherwise use the provided publish date.
- `slug`: use a stable URL-safe slug. Prefer an existing slug when present.
- `author.name`: use `chorbs` when not specified.
- `tags` and `categories`: preserve meaningful values when present; otherwise infer 1-3 useful Chinese values from the article.
- `summary`: write a concise Chinese summary if the note does not already provide one.
- `featuredImage`: if the article has images, use the first image filename as the featured image.

After creating the post, write `.publish-staging/result.json` with this shape:

```json
{
  "title": "文章标题",
  "slug": "post-slug",
  "postPath": "content/posts/post-slug/index.md",
  "status": "ready"
}
```

If the note cannot be safely published, do not create a post. Write `.publish-staging/result.json` with:

```json
{
  "status": "blocked",
  "reason": "简短说明"
}
```
