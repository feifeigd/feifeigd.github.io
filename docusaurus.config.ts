import type {Config} from '@docusaurus/types';

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
                },
            },
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
    },
}

export default config;
