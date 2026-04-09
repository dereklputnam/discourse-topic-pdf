import { apiInitializer } from "discourse/lib/api";
import TopicPdfButton from "../components/topic-pdf-button";

export default apiInitializer((api) => {
  api.renderInOutlet(
    "topic-navigation",
    <template>
      <TopicPdfButton @outletArgs={{@outletArgs}} />
    </template>
  );
});
