import TicketingSystemNewTicketForm from "../../components/ticketing-system/new-ticket-form";

// /tickets/new —— 新建工单。
//
// 表单状态（标题、正文、部门、优先级、提交中、错误）都住在组件里，所以这里
// 只是一个转发。未登录的访客已经在 `routes/ticketing-system/new.js` 里被转走了。
export default <template>
  <TicketingSystemNewTicketForm />
</template>
