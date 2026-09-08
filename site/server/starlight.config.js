export const siteConfig = {
  title: 'preen',
  description:
    'Browse markdown and diffs in the terminal, without opening an editor — thin glue over glow, delta and fzf.',
  logo: null,
  editUrlBase: 'https://github.com/beatzball/preen/edit/main/site/content/docs',
  nav: [
    { label: 'Docs', href: '/docs/getting-started' },
    { label: 'GitHub', href: 'https://github.com/beatzball/preen' },
  ],
  sidebar: [
    {
      label: 'Start Here',
      items: [
        { label: 'Getting Started', slug: 'getting-started' },
        { label: 'Browsing',        slug: 'browsing' },
      ],
    },
    {
      label: 'Modes',
      items: [
        { label: 'Pipes',         slug: 'pipes' },
        { label: 'Pull Requests', slug: 'pull-requests' },
        { label: 'Worktrees',     slug: 'worktrees' },
      ],
    },
    {
      label: 'Reference',
      items: [
        { label: 'Git Integration', slug: 'git-integration' },
        { label: 'Theming',         slug: 'theming' },
      ],
    },
  ],
};

export default siteConfig;
