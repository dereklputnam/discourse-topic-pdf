import { apiInitializer } from "discourse/lib/api";
import TopicPdfButton from "../components/topic-pdf-button";

export default apiInitializer((api) => {
  const outlet = settings.button_location || "topic-above-post-stream";

  api.renderInOutlet(
    outlet,
    <template>
      <TopicPdfButton @outletArgs={{@outletArgs}} />
    </template>
  );
});
