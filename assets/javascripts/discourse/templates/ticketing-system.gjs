import { LinkTo } from "@ember/routing";
import { i18n } from "discourse-i18n";

// 用户侧的外壳，三个页面（列表 / 新建 / 详情）共用。
//
// 这个文件**必须存在**，即使内容再空。父路由 `ticketing-system` 如果找不到同名模板，
// 默认的 renderTemplate 什么也不渲染 —— 包括那个 `{{outlet}}`，于是三个子路由
// 全部渲染不出来，URL 正常、控制台干净、页面空白。
//
// 这里刻意只放一个容器和一个导航链接：标题由各页面自己给（列表页是
// "Support tickets"，详情页是工单标题），外壳再放一遍就是重复。
export default <template>
  <div class="ts-app">
    <nav class="ts-app__nav">
      <LinkTo @route="ticketing-system.index" class="ts-app__nav-link">
        {{i18n "ticketing_system.nav_label"}}
      </LinkTo>
    </nav>

    {{outlet}}
  </div>
</template>
