
import DefaultTheme from 'vitepress/theme'
import Page from "../../components/Page.vue";

export default {
	...DefaultTheme,
    enhanceApp({ app }) {
        // register global components
        app.component('Page', Page);
    }
}
