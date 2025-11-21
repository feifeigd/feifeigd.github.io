
import { getSideBar } from "vitepress-plugin-autobar";
import { defineConfig } from "vitepress";
import { withPwa  } from "@vite-pwa/vitepress";

// https://vitepress.dev/reference/site-config

export default withPwa(defineConfig({
    title: "第七空间",
    description: "个人博客",
    
    cleanUrls: true,

    // 主题配置
    themeConfig: {
    //     // package.json 根目录下的 docs 目录
    //     sidebar: getSideBar("docs", {
    //         ignoreMDFiles: ["index"],
    //         ignoreDirectory: ["node_modules"],
    //     }),
        // siteTitle: false,   // 隐藏左上角标题
        nav: [
            // { text: 'Guide', link: '/guide' },
            { text: 'Configs', link: '/configs' },
            { text: 'Github', link: 'https://github.com/feifeigd' },
            // 下拉列表
            {
              text: 'Packages',
              items: [
                { text: 'Foo', link: '/packages/foo' },
                { text: 'Bar', link: '/packages/bar' },
              ],
            },
        ],
        sidebar: [
            // {
            //     text: 'Guide',
            //     items: [
            //         { text: 'Introduction', link: '/introduction' },
            //         { text: 'Getting Started', link: '/getting-started' },
            //     ]
            // },
            {
                text: 'Examples',
                items: [
                    { text: 'Markdown Examples', link: '/markdown-examples', }, 
                    { text: 'Runtime API Examples', link: '/api-examples', }, 
                ]
            },
        ],
        
        socialLinks: [
            {icon: 'github', link: 'https://github.com/vuejs/vitepress'}
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

    },

    // Vite PWA Options
    pwa: {
        manifest: {
            // fix WARNING: "theme_color" is missing from the web manifest, your application will not be able to be installed
            theme_color: "#42b983",
        },
        workbox: {

        }
    },
    // .md 目录与 .vitepress 目录同级
    srcDir: ".",
    vite: {
        // 定义常量
        define: {
            __DATE__: `"${new Date().toString()}"`,
        },
    },
}));
