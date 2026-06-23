import type {Config} from '@docusaurus/types';

const config: Config = {
    title: 'D7kj',
    tagline: '大飞哥的个人博客',

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
                docs: false,
                blog: false,
            },
        ],
    ],
}

export default config;
