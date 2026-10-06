import TicketingSystemTicketDetail from "../../components/ticketing-system/ticket-detail";

// /tickets/:id —— 工单详情。
//
// `@model` 是 `routes/ticketing-system/show.js` 的返回值，形状固定为
// `{ ticket, error }`（恰好一个非空）。组件自己决定渲染哪一种。
//
// 只透传，不做判断：判断放在组件里，是因为组件在 5 号工单 → 6 号工单的跳转中会被
// 复用（构造器不重跑），"渲染哪个分支" 必须跟着 `@model` 每次变化重新算。
export default <template>
  <TicketingSystemTicketDetail @model={{@model}} />
</template>
