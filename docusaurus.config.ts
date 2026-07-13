import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import {themes as prismThemes} from 'prism-react-renderer';

const config: Config = {
  title: 'd7kj',
  tagline: '游戏服务器与 Web 后端工程师',

  future: {
    v4: true,
  },

  url: 'https://feifeigd.github.io',
  baseUrl: '/',
  organizationName: 'd7kj',
  projectName: 'feifeigd.github.io',

  onBrokenLinks: 'throw',

  markdown: {
    mermaid: true,
  },

  themes: ['@docusaurus/theme-mermaid'],

  i18n: {
    defaultLocale: 'zh-Hans',
    locales: ['zh-Hans'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: 'https://github.com/feifeigd/feifeigd.github.io/edit/main/',
        },
        blog: {
          showReadingTime: true,
          feedOptions: {
            type: 'all',
            xslt: true,
          },
          editUrl: 'https://github.com/feifeigd/feifeigd.github.io/edit/main/blog/',
          onInlineTags: 'warn',
          onInlineAuthors: 'warn',
          onUntruncatedBlogPosts: 'warn',
        },
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/docusaurus-social-card.jpg',
    colorMode: {
      defaultMode: 'light',
      disableSwitch: false,
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'd7kj',
      logo: {
        alt: 'd7kj Logo',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: '技术文档',
        },
        {
          to: '/ai',
          label: 'AI专题',
          position: 'left',
        },
        {
          to: '/blog',
          label: '博客',
          position: 'left',
        },
        {
          href: 'https://github.com/feifeigd',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: '内容',
          items: [
            {
              label: '技术文档',
              to: '/docs/',
            },
            {
              label: '博客',
              to: '/blog',
            },
          ],
        },
        {
          title: '联系',
          items: [
            {
              label: 'Email',
              href: 'mailto:502207456@qq.com',
            },
            {
              label: '个人主页',
              href: 'https://www.d7kj.com',
            },
            {
              label: 'GitHub',
              href: 'https://github.com/feifeigd',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} d7kj. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
    mermaid: {
      theme: {light: 'neutral', dark: 'dark'},
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
