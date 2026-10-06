import TicketingSystemTicketList from "../../components/ticketing-system/ticket-list";

// /tickets —— 工单列表。
//
// 这里没有 `@model`：列表自己管筛选、分页和请求（见 ticket-list.gjs 里的说明）。
// 路由层唯一提供的东西是父路由已经取好的元数据，组件通过 service 读它。
export default <template>
  <TicketingSystemTicketList />
</template>
