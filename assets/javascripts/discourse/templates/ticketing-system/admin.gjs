import TicketingSystemAdminPanel from "../../components/ticketing-system/admin-panel";

// /tickets/admin —— 管理页。
//
// 和另外三个模板一样只做转发：标签页的选中状态属于组件，不是路由状态。
//
// 为什么不把标签页拆成子路由（/tickets/admin/overview 之类）：那需要在
// `ticketing-system-route-map.js` 里多加两条路由、在 Rails 的 `config/routes.rb`
// 里多加两条页面外壳路由，而它们全都渲染同一个空壳 —— 收益只是地址栏好看一点，
// 代价是四条路径都要各自保证「刷新不 404」。标签页是视图状态，不是位置。
export default <template>
  <TicketingSystemAdminPanel />
</template>
