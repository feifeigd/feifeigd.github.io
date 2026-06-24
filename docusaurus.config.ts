import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import {themes as prismThemes} from 'prism-react-renderer';

const config: Config = {
    title: 'D7kj',
    tagline: '大飞哥的个人博客',

    future: {
        v4: true,
    },

    url: 'https://feifeigd.github.io',
    // Set the /<baseUrl> pathname under which your site is served.
    // For GitHub pages deployment, it is often '/<projectName>/'
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
                    showReadingTime: true,  // 显示阅读时间
                    feedOptions: {
                        type: 'all',
                        xslt: true,
                    },
                    editUrl: 'https://github.com/feifeigd/feifeigd.github.io/edit/main/blog/',
                    onInlineTags: 'warn',  // 显示标签
                    onInlineAuthors: 'warn',  // 显示作者
                    onUntruncatedBlogPosts: 'warn',  // 显示未截断的博客文章
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
        // 顶部导航条
        navbar: {
            title: 'D7kj',
            logo: {
                alt: 'D7kj Logo',
                src: 'img/logo.svg',  // static/img/logo.svg
            },
            items: [
                {
                    type: 'docSidebar',
                    sidebarId: 'tutorialSidebar',
                    position: 'left',
                    label: 'Tutorial',
                },
                {
                    to: '/blog',
                    label: 'Blog',
                    position: 'left',
                },
                {
                    href: 'https://github.com/feifeigd/feifeigd.github.io',
                    label: 'GitHub',
                    position: 'right',
                },
            ],
        },
        footer: {
            style: 'dark',
            links: [
                {
                    title: 'Docs',
                    items: [
                        {
                            label: 'Tutorial',
                            to: '/docs/intro',
                        },
                    ],
                },
                {
                    title: 'Community',
                    items: [
                        {
                            label: 'Stack Overflow',
                            href: 'https://stackoverflow.com/questions/tagged/docusaurus',
                        },
                        {
                            label: 'Discord',
                            href: 'https://discordapp.com/invite/docusaurus',
                        },
                        {
                            label: 'X',
                            href: 'https://x.com/docusaurus',
                        },
                    ],
                },
                {
                    title: 'More',
                    items: [
                        {
                            label: 'Blog',
                            to: '/blog',
                        },
                        {
                            label: 'GitHub',
                            href: 'https://github.com/feifeigd/feifeigd.github.io',
                        },
                    ],
                },
            ],
            copyright: `Copyright © ${new Date().getFullYear()} D7kj, Inc. Built with Docusaurus.`,
        },
        prism: {
            theme: prismThemes.github,
            darkTheme: prismThemes.dracula,
        },
        mermaid: {
            theme: {light: 'neutral', dark: 'dark'},
        },        
    } satisfies Preset.ThemeConfig,
}

export default config;
