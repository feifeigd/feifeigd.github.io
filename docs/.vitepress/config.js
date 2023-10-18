
import { getSideBar } from "vitepress-plugin-autobar";

module.exports = {
    title: "第七空间",
    description: "个人博客",

    themeConfig: {
    //     // package.json 根目录下的 docs 目录
    //     sidebar: getSideBar("docs", {
    //         ignoreMDFiles: ["index"],
    //         ignoreDirectory: ["node_modules"],
    //     }),
        // siteTitle: false,   // 隐藏左上角标题
        nav: [
            { text: 'Guide', link: '/guide' },
            { text: 'Configs', link: '/configs' },
            { text: 'Github', link: 'https://github.com/feifeigd' }
        ],
        sidebar: [
            {
                text: 'Guide',
                items: [
                    { text: 'Introduction', link: '/introduction' },
                    { text: 'Getting Started', link: '/getting-started' },
                ]
            },
        ],
        footer: {
            message: '第七空间 d7kj.com.<div>备案号：<a href="http://beian.miit.gov.cn/">粤ICP备12018578号</a></div>',
            copyright: 'Copyright © 2012-present d7kj',
        }
    },
    markdown: {
        // options for markdown-it-anchor
        // anchor: { permalink: false },
        // options for markdown-it-toc
        // toc: { includeLevel: [1, 2] },
        config: (md) => {
          // use more markdown-it plugins!
        //   md.use(require('markdown-it-xxx'))
        }

    }
};
